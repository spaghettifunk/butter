//! Fuzzy Search
//! Implements fuzzy string matching for the command palette.

const std = @import("std");

/// Maximum number of matched character positions to track.
pub const max_positions = 64;

/// Result of a fuzzy match operation.
pub const FuzzyMatch = struct {
    /// Score indicating match quality (higher is better).
    score: i32,
    /// Indices of matched characters in the target string (for highlighting).
    positions: [max_positions]u8,
    /// Number of valid positions in the positions array.
    position_count: usize,
};

/// Perform fuzzy matching of a query against a target string.
/// Returns a FuzzyMatch if the query matches, or null if it doesn't.
///
/// Scoring:
/// - Start of word bonus: +10
/// - CamelCase transition bonus: +10
/// - Consecutive match bonus: +5
/// - Base match: +1
/// - Gap penalty: -1
pub fn fuzzyMatch(query: []const u8, target: []const u8) ?FuzzyMatch {
    if (query.len == 0) {
        return FuzzyMatch{
            .score = 0,
            .positions = undefined,
            .position_count = 0,
        };
    }

    if (target.len == 0) {
        return null;
    }

    var score: i32 = 0;
    var query_idx: usize = 0;
    var positions: [max_positions]u8 = undefined;
    var pos_count: usize = 0;
    var prev_matched = false;
    var prev_lower = false;
    var prev_separator = true;

    for (target, 0..) |tc, i| {
        if (query_idx >= query.len) break;

        const qc = std.ascii.toLower(query[query_idx]);
        const target_lower = std.ascii.toLower(tc);

        if (qc == target_lower) {
            // Match found - record position for highlighting
            if (pos_count < max_positions) {
                positions[pos_count] = @intCast(i);
                pos_count += 1;
            }

            // Scoring bonuses
            if (prev_separator) {
                score += 10; // Start of word bonus
            }
            if (prev_lower and std.ascii.isUpper(tc)) {
                score += 10; // CamelCase transition bonus
            }
            if (prev_matched) {
                score += 5; // Consecutive match bonus
            }

            score += 1; // Base match score
            query_idx += 1;
            prev_matched = true;
        } else {
            prev_matched = false;
            score -= 1; // Gap penalty
        }

        prev_lower = std.ascii.isLower(tc);
        prev_separator = isSeparator(tc);
    }

    // All query characters must match
    if (query_idx < query.len) {
        return null;
    }

    return FuzzyMatch{
        .score = score,
        .positions = positions,
        .position_count = pos_count,
    };
}

/// Check if a character is a word separator.
fn isSeparator(c: u8) bool {
    return c == ' ' or c == '_' or c == '.' or c == '/' or c == '-' or c == ':';
}

/// Result entry for sorted search results.
pub const SearchResult = struct {
    index: usize,
    match: FuzzyMatch,
};

/// Compare function for sorting search results by score (descending).
fn compareByScore(_: void, a: SearchResult, b: SearchResult) bool {
    return a.match.score > b.match.score;
}

/// Sort an array of search results by score in descending order.
pub fn sortByScore(results: []SearchResult) void {
    std.mem.sort(SearchResult, results, {}, compareByScore);
}
