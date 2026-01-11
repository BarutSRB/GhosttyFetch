const std = @import("std");
const types = @import("types.zig");
const paths = @import("paths.zig");

const Allocator = types.Allocator;
const ColorPreferences = types.ColorPreferences;
const GradientPreferences = types.GradientPreferences;
const TerminalSize = types.TerminalSize;
const LayoutDimensions = types.LayoutDimensions;
const FramesFile = types.FramesFile;
const span_open = types.span_open;
const span_close = types.span_close;
const reset_code = types.reset_code;
const data_file = types.data_file;
const min_info_panel_width = types.min_info_panel_width;

// Private types
const Glyph = struct {
    buf: [4]u8 = [_]u8{ 0, 0, 0, 0 },
    len: u8 = 0,
    branded: bool = false,
};

const MarkupSegment = struct {
    text: []const u8,
    is_branded: bool,
};

const ParsedLine = struct {
    segments: []MarkupSegment,
    allocator: Allocator,

    fn parse(allocator: Allocator, line: []const u8) !ParsedLine {
        var segments = std.ArrayList(MarkupSegment).empty;
        errdefer segments.deinit(allocator);

        var i: usize = 0;
        var current_segment = std.ArrayList(u8).empty;
        var in_branded = false;

        while (i < line.len) {
            if (std.mem.startsWith(u8, line[i..], span_open)) {
                if (current_segment.items.len > 0) {
                    try segments.append(allocator, .{
                        .text = try current_segment.toOwnedSlice(allocator),
                        .is_branded = in_branded,
                    });
                    current_segment = std.ArrayList(u8).empty;
                }
                in_branded = true;
                i += span_open.len;
                continue;
            }

            if (std.mem.startsWith(u8, line[i..], span_close)) {
                if (current_segment.items.len > 0) {
                    try segments.append(allocator, .{
                        .text = try current_segment.toOwnedSlice(allocator),
                        .is_branded = in_branded,
                    });
                    current_segment = std.ArrayList(u8).empty;
                }
                in_branded = false;
                i += span_close.len;
                continue;
            }

            try current_segment.append(allocator, line[i]);
            i += 1;
        }

        if (current_segment.items.len > 0) {
            try segments.append(allocator, .{
                .text = try current_segment.toOwnedSlice(allocator),
                .is_branded = in_branded,
            });
        } else {
            current_segment.deinit(allocator);
        }

        return ParsedLine{
            .segments = try segments.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *ParsedLine) void {
        for (self.segments) |segment| {
            self.allocator.free(segment.text);
        }
        self.allocator.free(self.segments);
    }

    fn getPlainText(self: ParsedLine, allocator: Allocator) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        for (self.segments) |segment| {
            try result.appendSlice(allocator, segment.text);
        }

        return try result.toOwnedSlice(allocator);
    }

    /// Build a per-character brand mask for the plain text.
    /// Returns an array of bools, one per UTF-8 character (not byte), indicating if that character is branded.
    fn getBrandMask(self: ParsedLine, allocator: Allocator, plain: []const u8) ![]bool {
        var mask = std.ArrayList(bool).empty;
        errdefer mask.deinit(allocator);

        // Build a byte-to-brand lookup from segments
        var byte_to_brand = std.ArrayList(bool).empty;
        defer byte_to_brand.deinit(allocator);

        for (self.segments) |segment| {
            for (segment.text) |_| {
                try byte_to_brand.append(allocator, segment.is_branded);
            }
        }

        // Now iterate through plain text by characters (not bytes) and sample brand status
        var byte_idx: usize = 0;
        while (byte_idx < plain.len) {
            const is_branded = if (byte_idx < byte_to_brand.items.len)
                byte_to_brand.items[byte_idx]
            else
                false;
            try mask.append(allocator, is_branded);

            const char_len = std.unicode.utf8ByteSequenceLength(plain[byte_idx]) catch 1;
            byte_idx += char_len;
        }

        return try mask.toOwnedSlice(allocator);
    }
};

fn glyphEquals(a: Glyph, b: Glyph) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, a.buf[0..a.len], b.buf[0..b.len]);
}

fn clampCharLen(len: usize) usize {
    return if (len > 4) 4 else len;
}

fn buildCharPositions(allocator: Allocator, plain: []const u8) ![]usize {
    var char_positions = std.ArrayList(usize).empty;
    errdefer char_positions.deinit(allocator);

    var byte_idx: usize = 0;
    while (byte_idx < plain.len) {
        try char_positions.append(allocator, byte_idx);
        const char_len = std.unicode.utf8ByteSequenceLength(plain[byte_idx]) catch 1;
        const step = if (char_len == 0) 1 else char_len;
        const safe_step = if (byte_idx + step > plain.len) 1 else step;
        byte_idx += safe_step;
    }

    return try char_positions.toOwnedSlice(allocator);
}

const VerticalScaler = struct {
    fn resample(
        allocator: Allocator,
        lines: [][]const u8,
        target_height: usize,
        target_width: usize,
    ) ![][]const u8 {
        if (lines.len == 0) return try allocator.alloc([]const u8, 0);
        if (target_height == 0) return try allocator.alloc([]const u8, 0);

        var glyph_lines = std.ArrayList([]Glyph).empty;

        try glyph_lines.ensureTotalCapacityPrecise(allocator, lines.len);
        for (lines) |line| {
            var glyphs = try lineToGlyphs(allocator, line);
            glyphs = try ensureWidth(allocator, glyphs, target_width);
            glyph_lines.appendAssumeCapacity(glyphs);
        }
        defer freeGlyphLines(allocator, glyph_lines.items);

        const src_height = glyph_lines.items.len;

        // Dispatch based on scale direction
        if (src_height > target_height) {
            // DOWNSCALE: Use voting for better quality
            return try downsampleVoting(allocator, glyph_lines.items, target_height, target_width);
        } else {
            // UPSCALE: Use nearest-neighbor (fast, same quality)
            return try upsampleNearest(allocator, glyph_lines.items, target_height, target_width);
        }
    }

    /// Nearest-neighbor upscaling - simple and fast
    fn upsampleNearest(
        allocator: Allocator,
        glyph_lines: [][]Glyph,
        target_height: usize,
        _: usize, // target_width unused - lines already have correct width
    ) ![][]const u8 {
        const src_height = glyph_lines.len;

        var result = std.ArrayList([]const u8).empty;
        errdefer {
            for (result.items) |line| allocator.free(line);
            result.deinit(allocator);
        }
        try result.ensureTotalCapacityPrecise(allocator, target_height);

        // Handle edge case: if src_height == 1, just repeat that line
        if (src_height == 1) {
            var i: usize = 0;
            while (i < target_height) : (i += 1) {
                const markup_line = try glyphsToMarkupLine(allocator, glyph_lines[0]);
                try result.append(allocator, markup_line);
            }
        } else {
            const step = @as(f64, @floatFromInt(src_height - 1)) /
                @as(f64, @floatFromInt(target_height - 1));

            var i: usize = 0;
            while (i < target_height) : (i += 1) {
                const source_idx = @as(usize, @intFromFloat(@as(f64, @floatFromInt(i)) * step));
                const clamped_idx = if (source_idx >= src_height) src_height - 1 else source_idx;

                const markup_line = try glyphsToMarkupLine(allocator, glyph_lines[clamped_idx]);
                try result.append(allocator, markup_line);
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    /// Voting-based downscaling - picks dominant glyph per column for better quality
    fn downsampleVoting(
        allocator: Allocator,
        glyph_lines: [][]Glyph,
        target_height: usize,
        target_width: usize,
    ) ![][]const u8 {
        const src_height = glyph_lines.len;

        var result = std.ArrayList([]const u8).empty;
        errdefer {
            for (result.items) |line| allocator.free(line);
            result.deinit(allocator);
        }
        try result.ensureTotalCapacityPrecise(allocator, target_height);

        var i: usize = 0;
        while (i < target_height) : (i += 1) {
            var out_glyphs = try allocator.alloc(Glyph, target_width);
            defer allocator.free(out_glyphs);

            const range = sampleRange(src_height, target_height, i);

            var col: usize = 0;
            while (col < target_width) : (col += 1) {
                const vote = voteColumn(glyph_lines[range.start..range.end], col);
                out_glyphs[col] = vote;
            }

            const markup_line = try glyphsToMarkupLine(allocator, out_glyphs);
            try result.append(allocator, markup_line);
        }

        return try result.toOwnedSlice(allocator);
    }

    fn sampleRange(src_len: usize, target_len: usize, idx: usize) struct { start: usize, end: usize } {
        const start = (idx * src_len) / target_len;
        const end = ((idx + 1) * src_len + target_len - 1) / target_len;
        if (end <= start) {
            return .{ .start = start, .end = if (start + 1 > src_len) src_len else start + 1 };
        }
        return .{ .start = start, .end = if (end > src_len) src_len else end };
    }

    fn voteColumn(lines: [][]Glyph, column: usize) Glyph {
        const max_variants = 16;
        const Variant = struct { glyph: Glyph, count: usize };
        var variants: [max_variants]Variant = undefined;
        var variant_count: usize = 0;

        var brand_votes: usize = 0;
        var total_votes: usize = 0;

        for (lines) |glyphs| {
            if (column >= glyphs.len) continue;
            const g = glyphs[column];
            total_votes += 1;
            if (g.branded) brand_votes += 1;

            var found = false;
            var vi: usize = 0;
            while (vi < variant_count) : (vi += 1) {
                if (glyphEquals(variants[vi].glyph, g)) {
                    variants[vi].count += 1;
                    found = true;
                    break;
                }
            }

            if (!found and variant_count < max_variants) {
                variants[variant_count] = .{ .glyph = g, .count = 1 };
                variant_count += 1;
            }
        }

        const selected = blk: {
            if (variant_count == 0) break :blk Glyph{};
            var best = variants[0];
            var idx: usize = 1;
            while (idx < variant_count) : (idx += 1) {
                if (variants[idx].count > best.count) best = variants[idx];
            }
            break :blk best.glyph;
        };

        var chosen = selected;
        chosen.branded = brand_votes * 2 >= total_votes;
        return chosen;
    }
};

const HorizontalScaler = struct {
    fn resample(
        allocator: Allocator,
        line: []const u8,
        target_width: usize,
    ) ![]const u8 {
        if (target_width == 0) return try allocator.dupe(u8, "");

        var parsed = try ParsedLine.parse(allocator, line);
        defer parsed.deinit();

        const plain = try parsed.getPlainText(allocator);
        defer allocator.free(plain);

        const brand_mask = try parsed.getBrandMask(allocator, plain);
        defer allocator.free(brand_mask);

        const char_positions = try buildCharPositions(allocator, plain);
        defer allocator.free(char_positions);

        const num_chars = char_positions.len;
        if (num_chars == 0) {
            const blanks = try allocator.alloc(u8, target_width);
            @memset(blanks, ' ');
            return blanks;
        }

        // Dispatch based on scale direction
        if (num_chars > target_width) {
            // DOWNSCALE: Use voting for better quality
            return try downsampleVoting(allocator, plain, brand_mask, char_positions, target_width);
        } else {
            // UPSCALE: Use nearest-neighbor (fast, same quality)
            return try upsampleNearest(allocator, plain, brand_mask, char_positions, target_width);
        }
    }

    /// Nearest-neighbor upscaling - simple and fast
    fn upsampleNearest(
        allocator: Allocator,
        plain: []const u8,
        brand_mask: []const bool,
        char_positions: []const usize,
        target_width: usize,
    ) ![]const u8 {
        const num_chars = char_positions.len;

        var scaled_chars = std.ArrayList(u8).empty;
        errdefer scaled_chars.deinit(allocator);
        var scaled_mask = std.ArrayList(bool).empty;
        defer scaled_mask.deinit(allocator);
        try scaled_chars.ensureTotalCapacityPrecise(allocator, target_width * 2);
        try scaled_mask.ensureTotalCapacityPrecise(allocator, target_width);

        // Handle edge case: if num_chars == 1, just repeat that char
        if (num_chars == 1) {
            const byte_pos = char_positions[0];
            const char_len = std.unicode.utf8ByteSequenceLength(plain[byte_pos]) catch 1;
            const char_end = @min(byte_pos + char_len, plain.len);
            const slice = plain[byte_pos..char_end];
            const is_branded = if (brand_mask.len > 0) brand_mask[0] else false;

            var i: usize = 0;
            while (i < target_width) : (i += 1) {
                try scaled_chars.appendSlice(allocator, slice);
                try scaled_mask.append(allocator, is_branded);
            }
        } else {
            const step = @as(f64, @floatFromInt(num_chars - 1)) /
                @as(f64, @floatFromInt(target_width - 1));

            var i: usize = 0;
            while (i < target_width) : (i += 1) {
                const source_idx = @as(usize, @intFromFloat(@as(f64, @floatFromInt(i)) * step));
                const clamped_idx = if (source_idx >= num_chars) num_chars - 1 else source_idx;

                const byte_pos = char_positions[clamped_idx];
                const char_len_raw = std.unicode.utf8ByteSequenceLength(plain[byte_pos]) catch 1;
                const char_len = clampCharLen(char_len_raw);
                const char_end = @min(byte_pos + char_len, plain.len);

                try scaled_chars.appendSlice(allocator, plain[byte_pos..char_end]);
                const is_branded = if (clamped_idx < brand_mask.len) brand_mask[clamped_idx] else false;
                try scaled_mask.append(allocator, is_branded);
            }
        }

        const scaled_plain = try scaled_chars.toOwnedSlice(allocator);
        defer allocator.free(scaled_plain);
        const sampled_mask = try scaled_mask.toOwnedSlice(allocator);
        defer allocator.free(sampled_mask);

        return try reconstructFromMask(allocator, scaled_plain, sampled_mask);
    }

    /// Voting-based downscaling - picks dominant character for better quality
    fn downsampleVoting(
        allocator: Allocator,
        plain: []const u8,
        brand_mask: []const bool,
        char_positions: []const usize,
        target_width: usize,
    ) ![]const u8 {
        const num_chars = char_positions.len;

        var scaled_chars = std.ArrayList(u8).empty;
        errdefer scaled_chars.deinit(allocator);
        var scaled_mask = std.ArrayList(bool).empty;
        defer scaled_mask.deinit(allocator);
        try scaled_chars.ensureTotalCapacityPrecise(allocator, target_width * 2);
        try scaled_mask.ensureTotalCapacityPrecise(allocator, target_width);

        var i: usize = 0;
        while (i < target_width) : (i += 1) {
            const range = sampleRange(num_chars, target_width, i);

            const choice = chooseChar(
                plain,
                brand_mask,
                char_positions,
                range.start,
                range.end,
            );

            try scaled_chars.appendSlice(allocator, choice.slice);
            try scaled_mask.append(allocator, choice.branded);
        }

        const scaled_plain = try scaled_chars.toOwnedSlice(allocator);
        defer allocator.free(scaled_plain);
        const sampled_mask = try scaled_mask.toOwnedSlice(allocator);
        defer allocator.free(sampled_mask);

        return try reconstructFromMask(allocator, scaled_plain, sampled_mask);
    }

    const SampleChoice = struct { slice: []const u8, branded: bool };

    fn sampleRange(src_len: usize, target_len: usize, idx: usize) struct { start: usize, end: usize } {
        const start = (idx * src_len) / target_len;
        var end = ((idx + 1) * src_len + target_len - 1) / target_len;
        if (end <= start) end = start + 1;
        if (end > src_len) end = src_len;
        return .{ .start = start, .end = end };
    }

    fn chooseChar(
        plain: []const u8,
        brand_mask: []const bool,
        char_positions: []const usize,
        start: usize,
        end: usize,
    ) SampleChoice {
        const max_variants = 16;
        const Variant = struct { slice: []const u8, count: usize };
        var variants: [max_variants]Variant = undefined;
        var variant_count: usize = 0;

        var brand_votes: usize = 0;
        var total_votes: usize = 0;

        var idx: usize = start;
        while (idx < end) : (idx += 1) {
            total_votes += 1;
            if (idx < brand_mask.len and brand_mask[idx]) brand_votes += 1;

            const byte_pos = char_positions[idx];
            const char_len_raw = std.unicode.utf8ByteSequenceLength(plain[byte_pos]) catch 1;
            const char_len = clampCharLen(char_len_raw);
            const char_end = @min(byte_pos + char_len, plain.len);
            const slice = plain[byte_pos..char_end];

            var found = false;
            var v: usize = 0;
            while (v < variant_count) : (v += 1) {
                if (std.mem.eql(u8, variants[v].slice, slice)) {
                    variants[v].count += 1;
                    found = true;
                    break;
                }
            }

            if (!found and variant_count < max_variants) {
                variants[variant_count] = .{ .slice = slice, .count = 1 };
                variant_count += 1;
            }
        }

        if (variant_count == 0) {
            return .{ .slice = " ", .branded = false };
        }

        var best = variants[0];
        var v: usize = 1;
        while (v < variant_count) : (v += 1) {
            if (variants[v].count > best.count) best = variants[v];
        }

        const branded = brand_votes * 2 >= total_votes;
        return .{ .slice = best.slice, .branded = branded };
    }

    /// Reconstruct text with span markup based on a per-character brand mask.
    /// The brand_mask has one bool per character (not byte) in scaled_text.
    fn reconstructFromMask(
        allocator: Allocator,
        scaled_text: []const u8,
        brand_mask: []const bool,
    ) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        // Build character info (byte positions and lengths)
        var char_info = std.ArrayList(struct { byte_pos: usize, byte_len: usize }).empty;
        defer char_info.deinit(allocator);

        var byte_idx: usize = 0;
        while (byte_idx < scaled_text.len) {
            const char_len = std.unicode.utf8ByteSequenceLength(scaled_text[byte_idx]) catch 1;
            const char_end = @min(byte_idx + char_len, scaled_text.len);
            try char_info.append(allocator, .{ .byte_pos = byte_idx, .byte_len = char_end - byte_idx });
            byte_idx = char_end;
        }

        if (char_info.items.len == 0) {
            return try allocator.dupe(u8, scaled_text);
        }

        var in_span = false;
        for (char_info.items, 0..) |info, char_idx| {
            const is_branded = if (char_idx < brand_mask.len) brand_mask[char_idx] else false;

            // Handle span transitions
            if (is_branded and !in_span) {
                try result.appendSlice(allocator, span_open);
                in_span = true;
            } else if (!is_branded and in_span) {
                try result.appendSlice(allocator, span_close);
                in_span = false;
            }

            // Append the character
            try result.appendSlice(allocator, scaled_text[info.byte_pos .. info.byte_pos + info.byte_len]);
        }

        // Close any remaining span
        if (in_span) {
            try result.appendSlice(allocator, span_close);
        }

        return try result.toOwnedSlice(allocator);
    }
};

fn lineToGlyphs(allocator: Allocator, line: []const u8) ![]Glyph {
    var parsed = try ParsedLine.parse(allocator, line);
    defer parsed.deinit();

    const plain = try parsed.getPlainText(allocator);
    defer allocator.free(plain);

    const brand_mask = try parsed.getBrandMask(allocator, plain);
    defer allocator.free(brand_mask);

    const char_positions = try buildCharPositions(allocator, plain);
    defer allocator.free(char_positions);

    const glyphs = try allocator.alloc(Glyph, char_positions.len);
    errdefer allocator.free(glyphs);

    for (char_positions, 0..) |byte_pos, i| {
        const raw_len = std.unicode.utf8ByteSequenceLength(plain[byte_pos]) catch 1;
        const char_len = clampCharLen(raw_len);
        const char_end = @min(byte_pos + char_len, plain.len);

        var g = Glyph{};
        g.len = @as(u8, @intCast(char_end - byte_pos));
        g.branded = if (i < brand_mask.len) brand_mask[i] else false;
        @memset(g.buf[0..], 0);
        if (g.len > 0) {
            const len_usize: usize = @intCast(g.len);
            @memcpy(g.buf[0..len_usize], plain[byte_pos..char_end]);
        }

        glyphs[i] = g;
    }

    return glyphs;
}

fn ensureWidth(allocator: Allocator, glyphs: []Glyph, target_width: usize) ![]Glyph {
    if (glyphs.len == target_width) return glyphs;

    const result = try allocator.alloc(Glyph, target_width);
    errdefer allocator.free(result);
    const min_len = if (glyphs.len < target_width) glyphs.len else target_width;
    if (min_len > 0) {
        @memcpy(result[0..min_len], glyphs[0..min_len]);
    }
    if (target_width > min_len) {
        var i: usize = min_len;
        while (i < target_width) : (i += 1) {
            result[i] = Glyph{
                .buf = [_]u8{ ' ', 0, 0, 0 },
                .len = 1,
                .branded = false,
            };
        }
    }
    allocator.free(glyphs);
    return result;
}

fn freeGlyphLines(allocator: Allocator, lines: [][]Glyph) void {
    for (lines) |line| allocator.free(line);
    if (lines.len > 0) allocator.free(lines);
}

fn glyphsToMarkupLine(allocator: Allocator, glyphs: []const Glyph) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var in_span = false;
    for (glyphs) |g| {
        if (g.branded and !in_span) {
            try out.appendSlice(allocator, span_open);
            in_span = true;
        } else if (!g.branded and in_span) {
            try out.appendSlice(allocator, span_close);
            in_span = false;
        }

        if (g.len == 0) {
            try out.append(allocator, ' ');
        } else {
            const len_usize: usize = @intCast(g.len);
            try out.appendSlice(allocator, g.buf[0..len_usize]);
        }
    }

    if (in_span) try out.appendSlice(allocator, span_close);

    return try out.toOwnedSlice(allocator);
}

const ArtRange = struct {
    start: usize,
    end: usize,
    height: usize,
    has_content: bool,
};

fn scaleFrame(
    allocator: Allocator,
    original_frame: []const u8,
    target_width: usize,
    target_height: usize,
) ![]const u8 {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, original_frame, '\n');
    while (it.next()) |line| {
        try lines.append(allocator, line);
    }

    var h_scaled = std.ArrayList([]const u8).empty;
    errdefer {
        for (h_scaled.items) |line| allocator.free(line);
        h_scaled.deinit(allocator);
    }

    for (lines.items) |line| {
        const scaled_line = try HorizontalScaler.resample(allocator, line, target_width);
        try h_scaled.append(allocator, scaled_line);
    }

    const v_scaled = try VerticalScaler.resample(allocator, h_scaled.items, target_height, target_width);

    const result = try std.mem.join(allocator, "\n", v_scaled);

    for (v_scaled) |line| allocator.free(line);
    for (h_scaled.items) |line| allocator.free(line);
    h_scaled.deinit(allocator);

    return result;
}

pub fn normalizePanelWidth(width: usize) usize {
    // Return width as-is; the new calculateLayout already handles proportions.
    // For ultra-narrow terminals with info_width=0, callers should check for 0
    // and skip info panel rendering entirely.
    return width;
}

pub fn calculateLayout(term_size: TerminalSize) LayoutDimensions {
    const total_width: usize = @as(usize, term_size.width);
    const gap_width: usize = if (total_width >= 100) 8 else if (total_width >= 50) 4 else 2;

    // Ultra-narrow terminals: art only, no info panel
    if (total_width < 30) {
        return .{
            .art_width = total_width,
            .art_height = calculateArtHeight(term_size.height),
            .info_width = 0,
        };
    }

    // Calculate proportional widths that fit within terminal
    const available_for_panels = total_width -| gap_width;

    // Target proportions based on terminal size
    var art_width: usize = undefined;
    var info_width: usize = undefined;

    if (total_width >= 140) {
        // Large terminal: generous info panel
        info_width = @min(80, available_for_panels / 3);
        art_width = available_for_panels -| info_width;
    } else if (total_width >= 100) {
        // Medium-large: balanced
        info_width = @min(60, available_for_panels * 2 / 5);
        art_width = available_for_panels -| info_width;
    } else if (total_width >= 60) {
        // Medium: 60% art, 40% info
        art_width = (available_for_panels * 3) / 5;
        info_width = available_for_panels -| art_width;
    } else {
        // Small: prioritize art, minimal info
        art_width = (available_for_panels * 2) / 3;
        info_width = available_for_panels -| art_width;
    }

    // Apply minimum thresholds only if space allows
    const min_art: usize = 15;
    const min_info: usize = 20;

    // If info panel is too small to be useful, give space to art
    if (info_width < min_info and art_width + info_width >= min_art) {
        art_width = available_for_panels;
        info_width = 0;
    }
    // If art is too small, try to take from info
    else if (art_width < min_art and info_width > min_info) {
        const transfer = @min(min_art -| art_width, info_width -| min_info);
        art_width += transfer;
        info_width -= transfer;
    }

    return .{
        .art_width = art_width,
        .art_height = calculateArtHeight(term_size.height),
        .info_width = info_width,
    };
}

fn calculateArtHeight(term_height: u16) usize {
    const height: usize = @as(usize, term_height);
    const reserved_lines: usize = 3;
    if (height > reserved_lines + 10) {
        return height - reserved_lines;
    }
    return @max(10, height -| reserved_lines);
}

pub fn fpsToDelayNs(fps: f64) u64 {
    if (fps > 0) {
        const delay = @as(f64, @floatFromInt(std.time.ns_per_s)) / fps;
        return @as(u64, @intFromFloat(delay));
    }
    return 50 * std.time.ns_per_ms;
}

pub fn renderFrame(allocator: Allocator, frame: []const u8, prefs: ColorPreferences, frame_index: usize) ![]const u8 {
    const has_span = std.mem.indexOf(u8, frame, span_open) != null;
    const brand_color = if (prefs.enable and prefs.color_code != null) prefs.color_code.? else null;
    const gradient_active = prefs.enable and prefs.gradient.colors.len > 0;

    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |line| try lines.append(allocator, line);

    const art_range = if (gradient_active) detectArtRange(lines.items) else ArtRange{ .start = 0, .end = 0, .height = 0, .has_content = false };

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (lines.items, 0..) |line, line_idx| {
        const line_gradient = if (gradient_active) gradientColorForLine(art_range, prefs.gradient, line_idx, frame_index) else null;
        const base_color = line_gradient orelse (if (!has_span and brand_color != null and prefs.enable) brand_color else null);

        var color_active = false;
        if (base_color) |code| {
            try out.appendSlice(allocator, code);
            color_active = true;
        }

        var j: usize = 0;
        while (j < line.len) : (j += 1) {
            if (std.mem.startsWith(u8, line[j..], span_open)) {
                if (brand_color) |code| {
                    try out.appendSlice(allocator, code);
                    color_active = true;
                }
                j += span_open.len - 1;
                continue;
            }

            if (std.mem.startsWith(u8, line[j..], span_close)) {
                if (base_color) |code| {
                    try out.appendSlice(allocator, code);
                    color_active = true;
                } else if (color_active) {
                    try out.appendSlice(allocator, reset_code);
                    color_active = false;
                }
                j += span_close.len - 1;
                continue;
            }

            try out.append(allocator, line[j]);
        }

        if (color_active) try out.appendSlice(allocator, reset_code);
        if (line_idx + 1 < lines.items.len) try out.append(allocator, '\n');
    }

    return try out.toOwnedSlice(allocator);
}

fn detectArtRange(lines: []const []const u8) ArtRange {
    var start: usize = 0;
    var found = false;
    for (lines, 0..) |line, idx| {
        if (lineHasArt(line)) {
            start = idx;
            found = true;
            break;
        }
    }
    if (!found) return .{ .start = 0, .end = 0, .height = 0, .has_content = false };

    var end: usize = start;
    var idx: usize = lines.len;
    while (idx > start) {
        idx -= 1;
        if (lineHasArt(lines[idx])) {
            end = idx;
            break;
        }
    }

    return .{ .start = start, .end = end, .height = end - start + 1, .has_content = true };
}

fn lineHasArt(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (std.mem.startsWith(u8, line[i..], span_open)) {
            i += span_open.len - 1;
            continue;
        }
        if (std.mem.startsWith(u8, line[i..], span_close)) {
            i += span_close.len - 1;
            continue;
        }
        switch (line[i]) {
            ' ', '\t', '\r' => {},
            else => return true,
        }
    }
    return false;
}

fn gradientColorForLine(range: ArtRange, gradient: GradientPreferences, line_index: usize, frame_index: usize) ?[]const u8 {
    if (!range.has_content or gradient.colors.len == 0) return null;
    if (line_index < range.start or line_index > range.end) return null;
    if (range.height == 0) return null;

    const scroll_step = scrollOffset(range, gradient, frame_index);
    const relative = line_index - range.start;
    const shifted = if (range.height == 0) relative else (relative + range.height - scroll_step) % range.height;

    if (gradient.colors.len == 1 or range.height <= 1) return gradient.colors[0];

    const grad_idx = (shifted * (gradient.colors.len - 1)) / (range.height - 1);
    return gradient.colors[grad_idx];
}

fn scrollOffset(range: ArtRange, gradient: GradientPreferences, frame_index: usize) usize {
    if (!gradient.scroll or gradient.scroll_speed <= 0 or gradient.fps <= 0) return 0;
    if (range.height == 0) return 0;

    const elapsed = @as(f64, @floatFromInt(frame_index)) / gradient.fps;
    const steps_f = elapsed * gradient.scroll_speed;
    const steps = if (steps_f < 0) 0 else @as(usize, @intFromFloat(std.math.floor(steps_f)));
    if (steps == 0) return 0;
    return steps % range.height;
}

pub fn loadRawFrames(allocator: Allocator) ![]const []const u8 {
    const path = try animationPath(allocator);
    defer allocator.free(path);

    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
    defer allocator.free(raw);

    const parsed = try std.json.parseFromSlice(FramesFile, allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var frames = std.ArrayList([]const u8).empty;
    errdefer freeFrames(allocator, frames.items);

    for (parsed.value.frames) |frame_text| {
        const frame_copy = try allocator.dupe(u8, frame_text);
        frames.append(allocator, frame_copy) catch |err| {
            allocator.free(frame_copy);
            return err;
        };
    }

    return try frames.toOwnedSlice(allocator);
}

pub fn freeFrames(allocator: Allocator, frames: []const []const u8) void {
    for (frames) |frame| allocator.free(frame);
    allocator.free(frames);
}

fn animationPath(allocator: Allocator) ![]u8 {
    if (try paths.findDataFile(allocator, data_file)) |result| {
        return result.path;
    }
    return error.AnimationNotFound;
}

pub fn visibleWidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and text[i] != 'm') : (i += 1) {}
            if (i < text.len) i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, text[i..], span_open)) {
            i += span_open.len;
            continue;
        }

        if (std.mem.startsWith(u8, text[i..], span_close)) {
            i += span_close.len;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const step = if (len > 1 and i + len <= text.len) len else 1;
        i += step;
        w += 1;
    }
    return w;
}

/// Get the maximum visible width of any line in a single frame.
/// Use this instead of visibleWidth() when measuring multi-line frames.
pub fn frameVisibleWidth(frame: []const u8) usize {
    var max: usize = 0;
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |line| {
        const w = visibleWidth(line);
        if (w > max) max = w;
    }
    return max;
}

pub fn getFrameDimensions(frame: []const u8) struct { width: usize, height: usize } {
    var height: usize = 0;
    var max_width: usize = 0;
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |line| {
        height += 1;
        const w = visibleWidth(line);
        if (w > max_width) max_width = w;
    }
    return .{ .width = max_width, .height = height };
}

/// Lazy frame cache that scales and renders frames on-demand.
/// This provides instant resize response by deferring frame processing
/// until each frame is actually needed for display.
pub const LazyFrameCache = struct {
    allocator: Allocator,
    raw_frames: []const []const u8,
    target_width: usize,
    target_height: usize,
    prefs: ColorPreferences,
    cache: []?[]const u8,

    pub fn init(
        allocator: Allocator,
        raw_frames: []const []const u8,
        initial_width: usize,
        initial_height: usize,
        prefs: ColorPreferences,
    ) !LazyFrameCache {
        const cache = try allocator.alloc(?[]const u8, raw_frames.len);
        @memset(cache, null);

        return LazyFrameCache{
            .allocator = allocator,
            .raw_frames = raw_frames,
            .target_width = initial_width,
            .target_height = initial_height,
            .prefs = prefs,
            .cache = cache,
        };
    }

    pub fn deinit(self: *LazyFrameCache) void {
        for (self.cache) |maybe_frame| {
            if (maybe_frame) |frame| {
                self.allocator.free(frame);
            }
        }
        self.allocator.free(self.cache);
    }

    /// Get a frame, scaling and rendering on-demand if not cached.
    pub fn getFrame(self: *LazyFrameCache, frame_index: usize) ![]const u8 {
        if (frame_index >= self.cache.len) {
            return error.FrameIndexOutOfBounds;
        }

        // Return cached frame if available
        if (self.cache[frame_index]) |cached_frame| {
            return cached_frame;
        }

        // Scale the single frame
        const scaled = try scaleFrame(
            self.allocator,
            self.raw_frames[frame_index],
            self.target_width,
            self.target_height,
        );
        defer self.allocator.free(scaled);

        // Render the single frame (apply colors)
        const rendered = try renderFrame(
            self.allocator,
            scaled,
            self.prefs,
            frame_index,
        );

        // Store in cache
        self.cache[frame_index] = rendered;

        return rendered;
    }

    /// Invalidate cache and set new dimensions. This is instant - no computation.
    pub fn resize(self: *LazyFrameCache, new_width: usize, new_height: usize) void {
        // Only invalidate if dimensions actually changed
        if (new_width == self.target_width and new_height == self.target_height) {
            return;
        }

        // Free all cached frames
        for (self.cache) |maybe_frame| {
            if (maybe_frame) |frame| {
                self.allocator.free(frame);
            }
        }

        // Reset cache to all null
        @memset(self.cache, null);

        // Update dimensions
        self.target_width = new_width;
        self.target_height = new_height;
    }

    pub fn frameCount(self: *const LazyFrameCache) usize {
        return self.raw_frames.len;
    }
};
