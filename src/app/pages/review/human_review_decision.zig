//! Page-local form state for explicitly finalizing one pinned human Review.
//!
//! This module owns only ephemeral decision/summary input and diagnostics. It
//! never owns a Review binding, revision, operation identifier, result time,
//! Store request, or asynchronous lifecycle.

const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const committed_review = @import("../../../committed_review.zig");
const human_review_session = @import("../../human_review_session.zig");
const key_input = @import("../../key_input.zig");

pub const Focus = enum {
    approved,
    needs_changes,
    canceled,
    summary,
    submit,
};

pub const Feedback = enum {
    none,
    submitting,
    decision_required,
    needs_changes_evidence_required,
    invalid_summary,
    summary_too_long,
    binding_unavailable,
    edit_blocked,
    already_completing,
    already_completed,
    reload_required,
    store_unavailable,
    queue_changed,
    capacity,
    internal_failure,

    pub fn text(self: Feedback) []const u8 {
        return switch (self) {
            .none => "",
            .submitting => "Completing review...",
            .decision_required => "Select a decision before Submit",
            .needs_changes_evidence_required => "Needs changes requires a summary, accepted finding, or anchored note",
            .invalid_summary => "Summary contains text that cannot be stored",
            .summary_too_long => "Summary exceeds the 65,536-byte limit",
            .binding_unavailable => "Pinned review session changed; close and reopen the Review",
            .edit_blocked => "Review summary is not editable in the current session state",
            .already_completing => "Review completion is already in progress",
            .already_completed => "Review is already completed",
            .reload_required => "Review state changed unexpectedly; reload the pinned Review",
            .store_unavailable => "Review Store is unavailable",
            .queue_changed => "Review operation queue changed; retry after the current operation finishes",
            .capacity => "Review operation capacity is temporarily exhausted",
            .internal_failure => "Review result could not be prepared",
        };
    }
};

pub const Msg = union(enum) {
    close,
    focus_next,
    focus_previous,
    leave_summary,
    activate,
    summary_edit: ui.TextArea.Msg,
    summary_paste: []const u8,
};

pub const InputContext = struct {
    open: bool = false,
    focus: Focus = .approved,
    summary_editing: bool = false,
    read_only: bool = false,
};

pub const Action = union(enum) {
    none,
    submit: committed_review.ReviewResultValue,
};

const SummaryEditor = struct {
    area: ui.TextArea,

    fn init(allocator: std.mem.Allocator, initial: ?[]const u8) !SummaryEditor {
        return .{ .area = try ui.TextArea.init(allocator, .{
            .value = initial orelse "",
            .placeholder = "Optional human summary",
        }) };
    }

    fn deinit(self: *SummaryEditor) void {
        self.area.deinit();
        self.* = undefined;
    }

    fn text(self: *const SummaryEditor) []const u8 {
        return self.area.text();
    }

    fn optionalText(self: *const SummaryEditor) ?[]const u8 {
        const value = self.text();
        return if (value.len == 0) null else value;
    }

    fn update(self: *SummaryEditor, msg: ui.TextArea.Msg) !?Feedback {
        switch (msg) {
            .move_left, .move_right, .move_up, .move_down, .home, .end => {
                try self.area.update(msg);
                return null;
            },
            .insert, .insert_newline, .backspace, .delete, .clear => {},
        }

        var candidate = try ui.TextArea.init(self.area.allocator, .{
            .value = self.area.text(),
            .placeholder = self.area.placeholder,
        });
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        candidate.cursor = self.area.cursor;
        try candidate.update(msg);
        if (validateCandidate(candidate.text())) |feedback| return feedback;

        self.area.deinit();
        self.area = candidate;
        candidate_owned = false;
        return null;
    }

    fn paste(self: *SummaryEditor, pasted: []const u8) !?Feedback {
        if (pasted.len == 0) return null;
        if (self.area.text().len > committed_review.limits.max_body_bytes or
            pasted.len > committed_review.limits.max_body_bytes - self.area.text().len)
        {
            return .summary_too_long;
        }

        var candidate = try ui.TextArea.init(self.area.allocator, .{
            .value = self.area.text(),
            .placeholder = self.area.placeholder,
        });
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        candidate.cursor = self.area.cursor;
        try candidate.value.insertSlice(candidate.allocator, candidate.cursor, pasted);
        candidate.cursor += pasted.len;
        if (validateCandidate(candidate.text())) |feedback| return feedback;

        self.area.deinit();
        self.area = candidate;
        candidate_owned = false;
        return null;
    }

    fn scrollLine(self: *const SummaryEditor, visible_rows: u16) usize {
        if (visible_rows == 0) return self.area.cursorLine();
        const cursor_line = self.area.cursorLine();
        return if (cursor_line < visible_rows) 0 else cursor_line - visible_rows + 1;
    }
};

const Form = struct {
    summary: SummaryEditor,
    decision: ?committed_review.ReviewResultValue = null,
    focus: Focus = .approved,
    summary_editing: bool = false,
    feedback: Feedback = .none,

    fn deinit(self: *Form) void {
        self.summary.deinit();
        self.* = undefined;
    }
};

pub const State = struct {
    form: ?Form = null,

    pub fn deinit(self: *State) void {
        self.close();
        self.* = .{};
    }

    pub fn isOpen(self: *const State) bool {
        return self.form != null;
    }

    pub fn open(
        self: *State,
        allocator: std.mem.Allocator,
        presentation: human_review_session.Presentation,
    ) !void {
        self.close();
        const snapshot = presentation.snapshot orelse return error.SessionUnavailable;
        self.form = .{ .summary = try SummaryEditor.init(allocator, snapshot.summary) };
    }

    pub fn close(self: *State) void {
        if (self.form) |*form| form.deinit();
        self.form = null;
    }

    pub fn inputContext(
        self: *const State,
        presentation: ?human_review_session.Presentation,
    ) InputContext {
        const form = if (self.form) |*value| value else return .{};
        const read_only = if (presentation) |value| presentationReadOnly(value) else true;
        return .{
            .open = true,
            .focus = form.focus,
            .summary_editing = form.summary_editing,
            .read_only = read_only,
        };
    }

    pub fn selectedDecision(self: *const State) ?committed_review.ReviewResultValue {
        const form = if (self.form) |*value| value else return null;
        return form.decision;
    }

    pub fn focus(self: *const State) ?Focus {
        const form = if (self.form) |*value| value else return null;
        return form.focus;
    }

    pub fn summaryEditing(self: *const State) bool {
        const form = if (self.form) |*value| value else return false;
        return form.summary_editing;
    }

    pub fn summaryArea(self: *const State) ?*const ui.TextArea {
        const form = if (self.form) |*value| value else return null;
        return &form.summary.area;
    }

    pub fn summaryScrollLine(self: *const State, visible_rows: u16) usize {
        const form = if (self.form) |*value| value else return 0;
        return form.summary.scrollLine(visible_rows);
    }

    pub fn feedback(self: *const State) Feedback {
        const form = if (self.form) |*value| value else return .none;
        return form.feedback;
    }

    pub fn apply(
        self: *State,
        msg: Msg,
        presentation: human_review_session.Presentation,
    ) !Action {
        const form = if (self.form) |*value| value else return .none;
        const read_only = presentationReadOnly(presentation);
        switch (msg) {
            .close => {
                self.close();
                return .none;
            },
            .focus_next => {
                if (!read_only) {
                    form.summary_editing = false;
                    form.focus = nextFocus(form.focus);
                }
            },
            .focus_previous => {
                if (!read_only) {
                    form.summary_editing = false;
                    form.focus = previousFocus(form.focus);
                }
            },
            .leave_summary => if (!read_only and form.focus == .summary and form.summary_editing) {
                form.summary_editing = false;
            },
            .activate => {
                if (read_only) {
                    form.feedback = if (presentation.lifecycle == .completed)
                        .already_completed
                    else if (presentation.reconciliation == .reload_required)
                        .reload_required
                    else
                        .already_completing;
                    return .none;
                }
                switch (form.focus) {
                    .approved => form.decision = .approved,
                    .needs_changes => form.decision = .needs_changes,
                    .canceled => form.decision = .canceled,
                    .summary => form.summary_editing = true,
                    .submit => return self.preflight(presentation),
                }
                form.feedback = .none;
            },
            .summary_edit => |edit| {
                if (read_only or form.focus != .summary or !form.summary_editing) return .none;
                if (try form.summary.update(edit)) |validation| form.feedback = validation else form.feedback = .none;
            },
            .summary_paste => |text| {
                if (read_only or form.focus != .summary or !form.summary_editing) return .none;
                if (try form.summary.paste(text)) |validation| form.feedback = validation else form.feedback = .none;
            },
        }
        return .none;
    }

    pub fn markBindingUnavailable(self: *State) void {
        if (self.form) |*form| form.feedback = .binding_unavailable;
    }

    pub fn markFinalizeAccepted(self: *State) void {
        if (self.form) |*form| form.feedback = .submitting;
    }

    pub fn markFinalizeRejected(
        self: *State,
        reason: human_review_session.AdmissionFailure,
    ) void {
        if (self.form) |*form| form.feedback = switch (reason) {
            .store_unavailable => .store_unavailable,
            .queue_changed, .incompatible_queue => .queue_changed,
            .capacity => .capacity,
            .admission_closed => .already_completing,
            .preparation_failed => .internal_failure,
        };
    }

    pub fn markFinalizeError(self: *State, err: anyerror) void {
        if (self.form) |*form| form.feedback = switch (err) {
            error.Finalizing => .already_completing,
            error.Completed => .already_completed,
            error.ReloadRequired, error.QueueMismatch => .reload_required,
            error.OperationCapacity => .capacity,
            error.DraftRequired, error.NoHumanReviewSession => .binding_unavailable,
            error.EditBlocked => .edit_blocked,
            else => .internal_failure,
        };
    }

    fn preflight(
        self: *State,
        presentation: human_review_session.Presentation,
    ) Action {
        const form = if (self.form) |*value| value else return .none;
        const decision = form.decision orelse {
            form.feedback = .decision_required;
            return .none;
        };
        const snapshot = presentation.snapshot orelse {
            form.feedback = .binding_unavailable;
            return .none;
        };
        const summary = form.summary.optionalText();
        if (summary) |text| {
            committed_review.validateHumanSummaryText(text) catch |err| {
                form.feedback = validationFeedback(err);
                return .none;
            };
        }
        if (decision == .needs_changes and
            !committed_review.hasNeedsChangesEvidence(
                summary,
                snapshot.finding_dispositions,
                snapshot.anchored_notes,
            ))
        {
            form.feedback = .needs_changes_evidence_required;
            form.focus = .summary;
            form.summary_editing = true;
            return .none;
        }
        form.feedback = .none;
        return .{ .submit = decision };
    }

    pub fn submittedSummary(self: *const State) ?[]const u8 {
        const form = if (self.form) |*value| value else return null;
        return form.summary.optionalText();
    }
};

pub fn keyToMsg(context: InputContext, key: chasen.Key) ?Msg {
    if (!context.open) return null;
    if (key.matches(chasen.Key.escape, .{})) {
        return if (!context.read_only and context.focus == .summary and context.summary_editing)
            .leave_summary
        else
            .close;
    }
    if (key.matches(chasen.Key.tab, .{ .shift = true })) return .focus_previous;
    if (key.matches(chasen.Key.tab, .{})) return .focus_next;

    if (!context.read_only and context.focus == .summary and context.summary_editing) {
        if (textAreaMsg(key)) |msg| return .{ .summary_edit = msg };
        return null;
    }
    if (!key_input.hasCommandModifier(key) and key.codepoint == 'q') return .close;
    if (context.read_only) return null;
    if (key.matches(chasen.Key.enter, .{})) return .activate;
    if ((context.focus == .approved or context.focus == .needs_changes or context.focus == .canceled) and
        !key_input.hasCommandModifier(key) and key.codepoint == ' ') return .activate;
    if (key.matches(chasen.Key.up, .{}) or
        (!key_input.hasCommandModifier(key) and key.codepoint == 'k')) return .focus_previous;
    if (key.matches(chasen.Key.down, .{}) or
        (!key_input.hasCommandModifier(key) and key.codepoint == 'j')) return .focus_next;
    return null;
}

pub fn pasteToMsg(context: InputContext, text: []const u8) ?Msg {
    if (!context.open or context.read_only or context.focus != .summary or !context.summary_editing) return null;
    return .{ .summary_paste = text };
}

fn textAreaMsg(key: chasen.Key) ?ui.TextArea.Msg {
    if (key.matches(chasen.Key.enter, .{})) return .insert_newline;
    if (key.matches(chasen.Key.backspace, .{})) return .backspace;
    if (key.matches(chasen.Key.delete, .{})) return .delete;
    if (key.matches(chasen.Key.left, .{})) return .move_left;
    if (key.matches(chasen.Key.right, .{})) return .move_right;
    if (key.matches(chasen.Key.up, .{})) return .move_up;
    if (key.matches(chasen.Key.down, .{})) return .move_down;
    if (key.matches(chasen.Key.home, .{})) return .home;
    if (key.matches(chasen.Key.end, .{})) return .end;
    if (key_input.textInputCodepoint(key)) |codepoint| return .{ .insert = codepoint };
    return null;
}

fn nextFocus(focus: Focus) Focus {
    return switch (focus) {
        .approved => .needs_changes,
        .needs_changes => .canceled,
        .canceled => .summary,
        .summary => .submit,
        .submit => .approved,
    };
}

fn previousFocus(focus: Focus) Focus {
    return switch (focus) {
        .approved => .submit,
        .needs_changes => .approved,
        .canceled => .needs_changes,
        .summary => .canceled,
        .submit => .summary,
    };
}

fn presentationReadOnly(presentation: human_review_session.Presentation) bool {
    return presentation.lifecycle == .saving or
        presentation.lifecycle == .finalizing or
        presentation.lifecycle == .completed or
        presentation.reconciliation == .reload_required;
}

fn validateCandidate(text: []const u8) ?Feedback {
    if (text.len == 0) return null;
    committed_review.validateHumanSummaryText(text) catch |err| return validationFeedback(err);
    return null;
}

fn validationFeedback(err: anyerror) Feedback {
    return switch (err) {
        error.LimitExceeded => .summary_too_long,
        else => .invalid_summary,
    };
}

test "human review result summary adapter rejects invalid paste atomically and preserves graphemes" {
    var editor = try SummaryEditor.init(std.testing.allocator, "日本語 e\u{301} 👩‍🚀");
    defer editor.deinit();
    const original = try std.testing.allocator.dupe(u8, editor.text());
    defer std.testing.allocator.free(original);

    try std.testing.expectEqual(Feedback.invalid_summary, (try editor.paste("\x1b")).?);
    try std.testing.expectEqualStrings(original, editor.text());
    try std.testing.expectEqual(Feedback.invalid_summary, (try editor.paste("\xff")).?);
    try std.testing.expectEqualStrings(original, editor.text());

    try std.testing.expect((try editor.update(.backspace)) == null);
    try std.testing.expectEqualStrings("日本語 e\u{301} ", editor.text());
    try std.testing.expect((try editor.update(.backspace)) == null);
    try std.testing.expectEqualStrings("日本語 e\u{301}", editor.text());
    try std.testing.expect((try editor.update(.backspace)) == null);
    try std.testing.expectEqualStrings("日本語 ", editor.text());

    try std.testing.expect((try editor.update(.home)) == null);
    try std.testing.expect((try editor.update(.delete)) == null);
    try std.testing.expectEqualStrings("本語 ", editor.text());

    var multiline = try SummaryEditor.init(std.testing.allocator, "one\ntwo\nthree");
    defer multiline.deinit();
    try std.testing.expectEqual(@as(usize, 1), multiline.scrollLine(2));

    var empty = try SummaryEditor.init(std.testing.allocator, "erase me");
    defer empty.deinit();
    try std.testing.expect((try empty.update(.clear)) == null);
    try std.testing.expect(empty.optionalText() == null);

    const maximum = try std.testing.allocator.alloc(u8, committed_review.limits.max_body_bytes);
    defer std.testing.allocator.free(maximum);
    @memset(maximum, 'a');
    var bounded = try SummaryEditor.init(std.testing.allocator, maximum);
    defer bounded.deinit();
    try std.testing.expectEqual(Feedback.summary_too_long, (try bounded.paste("b")).?);
    try std.testing.expectEqual(committed_review.limits.max_body_bytes, bounded.text().len);
}

test "human review result key grammar keeps q editable and Escape close-only" {
    try std.testing.expectEqual(Msg.close, keyToMsg(.{ .open = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(Msg.close, keyToMsg(.{ .open = true, .focus = .summary }, .{ .codepoint = chasen.Key.escape }).?);
    const editing: InputContext = .{ .open = true, .focus = .summary, .summary_editing = true };
    try std.testing.expectEqual(Msg.leave_summary, keyToMsg(editing, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(
        Msg{ .summary_edit = .{ .insert = 'q' } },
        keyToMsg(editing, .{ .codepoint = 'q' }).?,
    );
    try std.testing.expectEqual(Msg.activate, keyToMsg(.{ .open = true, .focus = .summary }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expect(keyToMsg(.{ .open = true, .focus = .summary }, .{ .codepoint = ' ' }) == null);
    try std.testing.expect(keyToMsg(.{ .open = true, .focus = .submit }, .{ .codepoint = ' ' }) == null);
    try std.testing.expectEqual(Msg.close, keyToMsg(.{ .open = true, .read_only = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expect(keyToMsg(.{ .open = true, .read_only = true }, .{ .codepoint = chasen.Key.enter }) == null);
}

test "human review result preflight requires explicit evidence and preserves explicit decisions" {
    try std.testing.expect(!committed_review.hasNeedsChangesEvidence(null, &.{}, &.{}));
    try std.testing.expect(committed_review.hasNeedsChangesEvidence("human summary", &.{}, &.{}));
    const dispositions = [_]committed_review.FindingDisposition{.{
        .finding_id = .{ .bytes = "F-1" },
        .disposition = .accepted,
    }};
    try std.testing.expect(committed_review.hasNeedsChangesEvidence(null, &dispositions, &.{}));

    var snapshot = try human_review_session.DraftSnapshot.init(
        std.testing.allocator,
        null,
        &.{},
        &.{},
    );
    defer snapshot.deinit();
    const oid = try committed_review.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    const editable: human_review_session.Presentation = .{
        .binding = .{
            .review_repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000"),
            .review_id = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000"),
            .target = .{
                .object_format = .sha1,
                .source_kind = .branch_range,
                .base_oid = oid,
                .head_oid = oid,
                .diff_base_oid = oid,
            },
            .findings_digest = committed_review.Sha256Digest.hash("findings"),
        },
        .lifecycle = .editable,
        .snapshot = &snapshot,
        .reconciliation = .confirmed,
    };
    var state: State = .{};
    defer state.deinit();

    try state.open(std.testing.allocator, editable);
    try std.testing.expect(state.selectedDecision() == null);
    _ = try state.apply(.focus_next, editable);
    _ = try state.apply(.activate, editable);
    try std.testing.expectEqual(committed_review.ReviewResultValue.needs_changes, state.selectedDecision().?);
    _ = try state.apply(.focus_previous, editable);
    _ = try state.apply(.focus_previous, editable);
    try std.testing.expect((try state.apply(.activate, editable)) == .none);
    try std.testing.expectEqual(Feedback.needs_changes_evidence_required, state.feedback());
    try std.testing.expectEqual(Focus.summary, state.focus().?);
    _ = try state.apply(.{ .summary_paste = "要修正" }, editable);
    _ = try state.apply(.focus_next, editable);
    const needs_action = try state.apply(.activate, editable);
    try std.testing.expect(needs_action == .submit);
    try std.testing.expectEqual(committed_review.ReviewResultValue.needs_changes, needs_action.submit);
    try std.testing.expectEqualStrings("要修正", state.submittedSummary().?);

    try state.open(std.testing.allocator, editable);
    _ = try state.apply(.activate, editable);
    _ = try state.apply(.focus_previous, editable);
    const approved_action = try state.apply(.activate, editable);
    try std.testing.expect(approved_action == .submit);
    try std.testing.expectEqual(committed_review.ReviewResultValue.approved, approved_action.submit);

    try state.open(std.testing.allocator, editable);
    _ = try state.apply(.focus_next, editable);
    _ = try state.apply(.focus_next, editable);
    _ = try state.apply(.activate, editable);
    _ = try state.apply(.focus_next, editable);
    _ = try state.apply(.focus_next, editable);
    const canceled_action = try state.apply(.activate, editable);
    try std.testing.expect(canceled_action == .submit);
    try std.testing.expectEqual(committed_review.ReviewResultValue.canceled, canceled_action.submit);

    try state.open(std.testing.allocator, editable);
    _ = try state.apply(.close, editable);
    try std.testing.expect(!state.isOpen());

    try state.open(std.testing.allocator, editable);
    var saving = editable;
    saving.lifecycle = .saving;
    const saving_focus = state.focus();
    const saving_summary = state.submittedSummary();
    try std.testing.expect(state.inputContext(saving).read_only);
    try std.testing.expect((try state.apply(.focus_next, saving)) == .none);
    try std.testing.expectEqual(saving_focus, state.focus());
    try std.testing.expect((try state.apply(.{ .summary_paste = "blocked" }, saving)) == .none);
    try std.testing.expectEqual(saving_summary, state.submittedSummary());
    try std.testing.expect((try state.apply(.activate, saving)) == .none);
    try std.testing.expectEqual(Feedback.already_completing, state.feedback());
    try std.testing.expect(state.selectedDecision() == null);

    try state.open(std.testing.allocator, editable);
    var finalizing = editable;
    finalizing.lifecycle = .finalizing;
    try std.testing.expect((try state.apply(.activate, finalizing)) == .none);
    try std.testing.expectEqual(Feedback.already_completing, state.feedback());
    try std.testing.expect(state.selectedDecision() == null);

    var completed = editable;
    completed.lifecycle = .completed;
    try std.testing.expect((try state.apply(.activate, completed)) == .none);
    try std.testing.expectEqual(Feedback.already_completed, state.feedback());

    var reload_required = editable;
    reload_required.lifecycle = .failed;
    reload_required.reconciliation = .reload_required;
    try std.testing.expect((try state.apply(.activate, reload_required)) == .none);
    try std.testing.expectEqual(Feedback.reload_required, state.feedback());
}
