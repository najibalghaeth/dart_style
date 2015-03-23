// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style.src.source_writer;

import 'dart_formatter.dart';
import 'chunk.dart';
import 'debug.dart';
import 'line_splitter.dart';
import 'rule.dart';
import 'source_code.dart';
import 'whitespace.dart';

/// Takes the incremental serialized output of [SourceVisitor]--the source text
/// along with any comments and preserved whitespace--and produces a coherent
/// series of [Chunk]s which can then be split into physical lines.
///
/// Keeps track of leading indentation, expression nesting, and all of the hairy
/// code required to seamlessly integrate existing comments into the pure
/// output produced by [SourceVisitor].
class LineWriter {
  final DartFormatter _formatter;

  final SourceCode _source;

  final _buffer = new StringBuffer();

  final _chunks = <Chunk>[];

  /// The whitespace that should be written to [_chunks] before the next
  ///  non-whitespace token or `null` if no whitespace is pending.
  ///
  /// This ensures that changes to indentation and nesting also apply to the
  /// most recent split, even if the visitor "creates" the split before changing
  /// indentation or nesting.
  Whitespace _pendingWhitespace;

  /// The number of newlines that need to be written to [_buffer] before the
  /// next line can be output.
  ///
  /// Where [_pendingWhitespace] buffers between the [SourceVisitor] and
  /// [_chunks], this buffers between the [LineWriter] and [_buffer]. It ensures
  /// we don't have trailing newlines in the output.
  int _bufferedNewlines = 0;

  /// The indentation at the beginning of the current complete line being
  /// written.
  int _beginningIndent;

  /// The nested stack of rules that are currently in use.
  ///
  /// New chunks are implicitly split by the innermost rule when the chunk is
  /// ended.
  final _rules = <Rule>[];

  /// The nested stack of spans that are currently being written.
  final _openSpans = <Span>[];

  /// All of the spans that have been created and closed.
  final _spans = <Span>[];

  /// The current indentation and nesting levels.
  ///
  /// This is tracked as a stack of numbers. Each element in the stack
  /// represents a level of statement indentation. The number of the element is
  /// the current expression nesting depth for that statement.
  ///
  /// It's stored as a stack because expressions may contain statements which
  /// in turn contain other expressions. The nesting level of the inner
  /// expressions are unrelated to the surrounding ones. For example:
  ///
  ///     outer(invocation(() {
  ///       inner(lambda());
  ///     }));
  ///
  /// When writing `inner(lambda())`, we need to track its nesting level. At
  /// the same time, when the lambda is done, we need to return to the nesting
  /// level of `outer(invocation(...`.
  ///
  /// Start with an implicit entry so that top-level definitions and directives
  /// can be split.
  var _indentStack = [-1];

  /// The current indentation, not including expression nesting.
  int get _indent => _indentStack.length - 1;

  /// The nesting depth of the current inner-most block.
  int get _nesting => _indentStack.last;
  void set _nesting(int value) {
    _indentStack[_indentStack.length - 1] = value;
  }

  /// When not `null`, the nesting level of the current inner-most block after
  /// the next token is written.
  ///
  /// When the nesting level is increased, we don't want it to take effect until
  /// after at least one token has been written. That ensures that comments
  /// appearing before the first token are correctly indented. For example, a
  /// binary operator expression increases the nesting before the first operand
  /// to ensure any splits within the left operand are handled correctly. If we
  /// changed the nesting level immediately, then code like:
  ///
  ///     {
  ///       // comment
  ///       foo + bar;
  ///     }
  ///
  /// would incorrectly get indented because the line comment adds a split which
  /// would take the nesting level of the binary operator into account even
  /// though we haven't written any of its tokens yet.
  int _pendingNesting;

  /// The index of the "current" chunk being written.
  ///
  /// If the last chunk is still being appended to, this is its index.
  /// Otherwise, it is the index of the next chunk which will be created.
  int get _currentChunkIndex {
    if (_chunks.isEmpty) return 0;
    if (_chunks.last.canAddText) return _chunks.length - 1;
    return _chunks.length;
  }

  /// The offset in [_buffer] where the selection starts in the formatted code.
  ///
  /// This will be `null` if there is no selection or the writer hasn't reached
  /// the beginning of the selection yet.
  int _selectionStart;

  /// The length in [_buffer] of the selection in the formatted code.
  ///
  /// This will be `null` if there is no selection or the writer hasn't reached
  /// the end of the selection yet.
  int _selectionLength;

  /// Whether there is pending whitespace that depends on the number of
  /// newlines in the source.
  ///
  /// This is used to avoid calculating the newlines between tokens unless
  /// actually needed since doing so is slow when done between every single
  /// token pair.
  bool get needsToPreserveNewlines =>
      _pendingWhitespace == Whitespace.oneOrTwoNewlines ||
      _pendingWhitespace == Whitespace.spaceOrNewline;

  /// The number of characters of code that can fit in a single line.
  int get pageWidth => _formatter.pageWidth;

  /// The current innermost rule.
  Rule get rule => _rules.last;

  LineWriter(this._formatter, this._source) {
    indent(_formatter.indent);
    _beginningIndent = _formatter.indent;
  }

  /// Writes [string], the text for a single token, to the output.
  ///
  /// By default, this also implicitly adds one level of nesting if we aren't
  /// currently nested at all. We do this here so that if a comment appears
  /// after any token within a statement or top-level form and that comment
  /// leads to splitting, we correctly nest. Even pathological cases like:
  ///
  ///
  ///     import // comment
  ///         "this_gets_nested.dart";
  ///
  /// If we didn't do this here, we'd have to call [nestExpression] after the
  /// first token of practically every grammar production.
  void write(String string) {
    _emitPendingWhitespace();
    _writeText(string);

    if (_pendingNesting != null) {
      _nesting = _pendingNesting;
      _pendingNesting = null;
    }
  }

  /// Writes a [WhitespaceChunk] of [type].
  void writeWhitespace(Whitespace type) {
    _pendingWhitespace = type;
  }

  /// Write a split owned by the current innermost rule.
  ///
  /// Ignores nesting when split if [nest] is `false`. If unsplit, it expands
  /// to a space if [space] is `true`.
  Chunk split({bool nest: true, bool space}) {
    return _writeSplit(_indent, nest ? _nesting : -1, _rules.last,
        spaceWhenUnsplit: space);
  }

  /// Outputs the series of [comments] and associated whitespace that appear
  /// before [token] (which is not written by this).
  ///
  /// The list contains each comment as it appeared in the source between the
  /// last token written and the next one that's about to be written.
  ///
  /// [linesBeforeToken] is number of lines between the last comment (or
  /// previous token if there are no comments) and the next token.
  void writeComments(List<SourceComment> comments, int linesBeforeToken,
      String token) {
    // Corner case: if we require a blank line, but there exists one between
    // some of the comments, or after the last one, then we don't need to
    // enforce one before the first comment. Example:
    //
    //     library foo;
    //     // comment
    //
    //     class Bar {}
    //
    // Normally, a blank line is required after `library`, but since there is
    // one after the comment, we don't need one before it. This is mainly so
    // that commented out directives stick with their preceding group.
    if (_pendingWhitespace == Whitespace.twoNewlines &&
        comments.isNotEmpty &&
        comments.first.linesBefore < 2) {
      if (linesBeforeToken > 1) {
        _pendingWhitespace = Whitespace.newline;
      } else {
        for (var i = 1; i < comments.length; i++) {
          if (comments[i].linesBefore > 1) {
            _pendingWhitespace = Whitespace.newline;
            break;
          }
        }
      }
    }

    // Write each comment and the whitespace between them.
    for (var i = 0; i < comments.length; i++) {
      var comment = comments[i];

      preserveNewlines(comment.linesBefore);

      // Don't emit a space because we'll handle it below. If we emit it here,
      // we may get a trailing space if the comment needs a line before it.
      if (_pendingWhitespace == Whitespace.space) _pendingWhitespace = null;
      _emitPendingWhitespace();

      if (comment.linesBefore == 0) {
        // If we're sitting on a split, move the comment before it to adhere it
        // to the preceding text.
        if (_shouldMoveCommentBeforeSplit()) {
          _chunks.last.allowText();
        }

        // The comment follows other text, so we need to decide if it gets a
        // space before it or not.
        if (_needsSpaceBeforeComment(isLineComment: comment.isLineComment)) {
          _writeText(" ");
        }
      } else {
        // The comment starts a line, so make sure it stays on its own line.
        _writeHardSplit(nest: true, allowIndent: !comment.isStartOfLine,
            double: comment.linesBefore > 1);
      }

      _writeText(comment.text);

      if (comment.selectionStart != null) {
        startSelectionFromEnd(comment.text.length - comment.selectionStart);
      }

      if (comment.selectionEnd != null) {
        endSelectionFromEnd(comment.text.length - comment.selectionEnd);
      }

      // Make sure there is at least one newline after a line comment and allow
      // one or two after a block comment that has nothing after it.
      var linesAfter;
      if (i < comments.length - 1) {
        linesAfter = comments[i + 1].linesBefore;
      } else {
        linesAfter = linesBeforeToken;

        // Always force a newline after multi-line block comments. Prevents
        // mistakes like:
        //
        //     /**
        //      * Some doc comment.
        //      */ someFunction() { ... }
        if (linesAfter == 0 && comments.last.text.contains("\n")) {
          linesAfter = 1;
        }
      }

      if (linesAfter > 0) _writeHardSplit(nest: true, double: linesAfter > 1);
    }

    // If the comment has text following it (aside from a grouping character),
    // it needs a trailing space.
    if (_needsSpaceAfterLastComment(comments, token)) {
      _pendingWhitespace = Whitespace.space;
    }

    preserveNewlines(linesBeforeToken);
  }

  /// If the current pending whitespace allows some source discretion, pins
  /// that down given that the source contains [numLines] newlines at that
  /// point.
  void preserveNewlines(int numLines) {
    // If we didn't know how many newlines the user authored between the last
    // token and this one, now we do.
    switch (_pendingWhitespace) {
      case Whitespace.spaceOrNewline:
        if (numLines > 0) {
          _pendingWhitespace = Whitespace.nestedNewline;
        } else {
          _pendingWhitespace = Whitespace.space;
        }
        break;

      case Whitespace.oneOrTwoNewlines:
        if (numLines > 1) {
          _pendingWhitespace = Whitespace.twoNewlines;
        } else {
          _pendingWhitespace = Whitespace.newline;
        }
        break;
    }
  }

  /// Increases indentation of the next line by [levels].
  void indent([int levels = 1]) {
    while (levels-- > 0) _indentStack.add(-1);
  }

  /// Decreases indentation of the next line by [levels].
  void unindent([int levels = 1]) {
    while (levels-- > 0) _indentStack.removeLast();
  }

  /// Starts a new span with [cost].
  ///
  /// Each call to this needs a later matching call to [endSpan].
  void startSpan([int cost = Cost.normal]) {
    _openSpans.add(new Span(_currentChunkIndex, cost));
  }

  /// Ends the innermost span.
  void endSpan() {
    var span = _openSpans.removeLast();

    // If the span was discarded while it was still open, just forget about it.
    if (span == null) return;

    span.close(_currentChunkIndex);

    // A span that just covers a single chunk can't be split anyway.
    if (span.start == span.end) return;
    _spans.add(span);
  }

  /// Starts a new [Rule].
  ///
  /// If omitted, defaults to a new [SimpleRule].
  void startRule([Rule rule]) {
    if (rule == null) rule = new SimpleRule();
    _rules.add(rule);
  }

  /// Ends the innermost rule.
  void endRule() {
    _rules.removeLast();
  }

  /// Pre-emptively forces all of the current rules to become hard splits.
  ///
  /// This is called by [SourceVisitor] when it can determine that a rule will
  /// will always be split. Turning it (and the surrounding rules) into hard
  /// splits lets the writer break the output into smaller pieces for the line
  /// splitter, which helps performance and avoids failing on very large input.
  ///
  /// In particular, it's easy for the visitor to know that collections with a
  /// large number of items must split. Doing that early avoids crashing the
  /// splitter when it tries to recurse on huge collection literals.
  void forceRules() => _handleHardSplit();

  /// Increases the level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void nestExpression() {
    if (_pendingNesting != null) {
      _pendingNesting++;
    } else {
      _pendingNesting = _nesting + 1;
    }
  }

  /// Decreases the level of expression nesting.
  ///
  /// Expressions that are more nested will get increased indentation when split
  /// if the previous line has a lower level of nesting.
  void unnest() {
    // By the time the nesting is done, it should have emitted some text and
    // not be pending anymore.
    assert(_pendingNesting == null);

    _nesting--;
  }

  /// Marks the selection starting point as occurring [fromEnd] characters to
  /// the left of the end of what's currently been written.
  ///
  /// It counts backwards from the end because this is called *after* the chunk
  /// of text containing the selection has been output.
  void startSelectionFromEnd(int fromEnd) {
    assert(_chunks.isNotEmpty);
    _chunks.last.startSelectionFromEnd(fromEnd);
  }

  /// Marks the selection ending point as occurring [fromEnd] characters to the
  /// left of the end of what's currently been written.
  ///
  /// It counts backwards from the end because this is called *after* the chunk
  /// of text containing the selection has been output.
  void endSelectionFromEnd(int fromEnd) {
    assert(_chunks.isNotEmpty);
    _chunks.last.endSelectionFromEnd(fromEnd);
  }

  /// Finishes writing and returns a [SourceCode] containing the final output
  /// and updated selection, if any.
  SourceCode end() {
    if (_chunks.isNotEmpty) _completeLine(_chunks.length);

    // Be a good citizen, end with a newline.
    if (_source.isCompilationUnit) _buffer.write(_formatter.lineEnding);

    // If we haven't hit the beginning and/or end of the selection yet, they
    // must be at the very end of the code.
    if (_source.selectionStart != null) {
      if (_selectionStart == null) {
        _selectionStart = _buffer.length;
      }

      if (_selectionLength == null) {
        _selectionLength = _buffer.length - _selectionStart;
      }
    }

    return new SourceCode(_buffer.toString(),
        uri: _source.uri,
        isCompilationUnit: _source.isCompilationUnit,
        selectionStart: _selectionStart,
        selectionLength: _selectionLength);
  }

  /// Writes the current pending [Whitespace] to the output, if any.
  ///
  /// This should only be called after source lines have been preserved to turn
  /// any ambiguous whitespace into a concrete choice.
  void _emitPendingWhitespace() {
    if (_pendingWhitespace == null) return;
    // Output any pending whitespace first now that we know it won't be
    // trailing.
    switch (_pendingWhitespace) {
      case Whitespace.space:
        _writeText(" ");
        break;

      case Whitespace.newline:
        _writeHardSplit();
        break;

      case Whitespace.nestedNewline:
        _writeHardSplit(nest: true);
        break;

      case Whitespace.newlineFlushLeft:
        _writeHardSplit(allowIndent: false);
        break;

      case Whitespace.twoNewlines:
        _writeHardSplit(double: true);
        break;

      case Whitespace.spaceOrNewline:
      case Whitespace.oneOrTwoNewlines:
        // We should have pinned these down before getting here.
        assert(false);
        break;
    }

    _pendingWhitespace = null;
  }

  /// Returns `true` if the last chunk is a split that should be move after the
  /// comment that is about to be written.
  bool _shouldMoveCommentBeforeSplit() {
    // Not if there is nothing before it.
    if (_chunks.isEmpty) return false;

    // If the text before the split is an open grouping character, we don't
    // want to adhere the comment to that.
    var text = _chunks.last.text;
    return !text.endsWith("(") && !text.endsWith("[") && !text.endsWith("{");
  }

  /// Returns `true` if a space should be output between the end of the current
  /// output and the subsequent comment which is about to be written.
  ///
  /// This is only called if the comment is trailing text in the unformatted
  /// source. In most cases, a space will be output to separate the comment
  /// from what precedes it. This returns false if:
  ///
  /// *   This comment does begin the line in the output even if it didn't in
  ///     the source.
  /// *   The comment is a block comment immediately following a grouping
  ///     character (`(`, `[`, or `{`). This is to allow `foo(/* comment */)`,
  ///     et. al.
  bool _needsSpaceBeforeComment({bool isLineComment}) {
    // Not at the start of the file.
    if (_chunks.isEmpty) return false;

    // Not at the start of a line.
    if (!_chunks.last.canAddText) return false;

    var text = _chunks.last.text;
    if (text.endsWith("\n")) return false;

    // Always put a space before line comments.
    if (isLineComment) return true;

    // Block comments do not get a space if following a grouping character.
    return !text.endsWith("(") && !text.endsWith("[") && !text.endsWith("{");
  }

  /// Returns `true` if a space should be output after the last comment which
  /// was just written and the token that will be written.
  bool _needsSpaceAfterLastComment(List<SourceComment> comments, String token) {
    // Not if there are no comments.
    if (comments.isEmpty) return false;

    // Not at the beginning of a line.
    if (!_chunks.last.canAddText) return false;

    // Otherwise, it gets a space if the following token is not a delimiter or
    // the empty string, for EOF.
    return token != ")" && token != "]" && token != "}" &&
           token != "," && token != ";" && token != "";
  }

  /// Appends a hard split with the current indentation and nesting (the latter
  /// only if [nest] is `true`).
  ///
  /// If [double] is `true`, a double-split (i.e. a blank line) is output.
  ///
  /// If [allowIndent] is `false, then the split will always cause the next
  /// line to be at column zero. Otherwise, it uses the normal indentation and
  /// nesting behavior.
  void _writeHardSplit({bool nest: false, bool double: false,
      bool allowIndent: true}) {
    // A hard split overrides any other whitespace.
    _pendingWhitespace = null;

    var indent = _indent;
    var nesting = nest ? _nesting : -1;
    if (!allowIndent) {
      indent = 0;
      nesting = -1;
    }

    _writeSplit(indent, nesting, new HardSplitRule(), isDouble: double);
  }

  /// Ends the current chunk (if any) with the given split information.
  ///
  /// Returns the chunk.
  Chunk _writeSplit(int indent, int nesting, Rule rule,
      {bool isDouble, bool spaceWhenUnsplit}) {
    if (_chunks.isEmpty) return null;

    var chunk = _chunks.last;
    chunk.applySplit(indent, nesting, rule,
        isDouble: isDouble, spaceWhenUnsplit: spaceWhenUnsplit);

    if (chunk.isHardSplit) _handleHardSplit();

    return chunk;
  }

  /// Writes [text] to either the current chunk or a new one if the current
  /// chunk is complete.
  void _writeText(String text) {
    if (_chunks.isEmpty) {
      _chunks.add(new Chunk(text));
    } else if (_chunks.last.canAddText) {
      _chunks.last.appendText(text);
    } else {
      // Since we're about to write some text on the next line, we know the
      // previous one is fully done being tweaked and merged, so now we can see
      // if it can be split independently.
       _checkForCompleteLine(_chunks.length);

      _chunks.add(new Chunk(text));
    }
  }

  /// Checks to see if we the first [length] chunks can be processed as a
  /// single line and processes them if so.
  ///
  /// We want to send small lists of chunks to [LineSplitter] for performance.
  /// We can do that when we know one set of chunks will absolutely not affect
  /// anything following it. The rule for that is pretty simple: a hard newline
  /// that is not nested inside an expression.
  bool _checkForCompleteLine(int length) {
    if (length == 0) return false;

    // Hang on to the split info so we can reset the writer to start with it.
    var split = _chunks[length - 1];

    // Can only split on a hard line that is not nested in the middle of an
    // expression.
    if (!split.isHardSplit || split.nesting >= 0) return false;

    _completeLine(length);

    // Discard the formatted chunks and any spans contained in them.
    _chunks.removeRange(0, length);
    _spans.removeWhere((span) => span.shift(length));

    // Get ready for the next line.
    _bufferedNewlines = split.isDouble ? 2 : 1;
    _beginningIndent = split.indent;

    return true;
  }

  /// Hands off the first [length] chunks to the [LineSplitter] as a single
  /// logical line to be split.
  void _completeLine(int length) {
    assert(_chunks.isNotEmpty);

    // Write the newlines required by the previous line.
    for (var i = 0; i < _bufferedNewlines; i++) {
      _buffer.write(_formatter.lineEnding);
    }

    // If we aren't completing the entire set of chunks, get the subset that we
    // are completing.
    var chunks = _chunks;
    var spans = _spans;

    if (length < _chunks.length) {
      chunks = chunks.take(length).toList();
      spans = spans.where((span) => span.start <= length).toList();
    }

    if (debugFormatter) {
      dumpChunks(chunks);
      print(spans.join("\n"));
    }

    var splitter = new LineSplitter(_formatter.lineEnding, _formatter.pageWidth,
        chunks, spans, _beginningIndent);
    var selection = splitter.apply(_buffer);

    if (selection[0] != null) _selectionStart = selection[0];
    if (selection[1] != null) _selectionLength = selection[1] - _selectionStart;
  }

  /// Handles open multisplits and spans when a hard line occurs.
  ///
  /// Any active separable multisplits will get split in two at this point.
  /// Other multisplits are forced into the "hard" state. All of their previous
  /// splits are turned into explicit hard splits and any new splits for that
  /// multisplit become hard splits too.
  ///
  /// All open spans get discarded since they will never be satisfied.
  void _handleHardSplit() {
    // Discard all open spans. We don't remove them from the stack so that we
    // can still correctly count later calls to endSpan().
    for (var i = 0; i < _openSpans.length; i++) {
      _openSpans[i] = null;
    }

    // Tell each ongoing rule that it now contains a hard split and see if it
    // wants to harden itself.
    var hardenedRules = new Set();
    for (var i = 0; i < _rules.length; i++) {
      var rule = _rules[i];
      if (rule.hardenOnHardSplit) {
        _rules[i] = new HardSplitRule();
        hardenedRules.add(rule);
      }
    }

    // Harden any chunks whose rule was hardened.
    if (hardenedRules.isEmpty) return;
    for (var i = 0; i < _chunks.length; i++) {
      var chunk = _chunks[i];
      if (chunk.rule == null) continue;

      if (hardenedRules.contains(chunk.rule)) {
        chunk.harden();

        // Now that this chunk is a hard split, we may be able to format up to
        // it as its own line. If so, the chunks will get removed, so reset
        // the loop counter.
        if (_checkForCompleteLine(i + 1)) i = -1;
      }
    }
  }
}
