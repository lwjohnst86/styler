#' Transform files with transformer functions
#'
#' `transform_files` applies transformations to file contents and writes back
#' the result.
#' @param files A character vector with paths to the file that should be
#'   transformed.
#' @inheritParams make_transformer
#' @section Value:
#' Invisibly returns a data frame that indicates for each file considered for
#' styling whether or not it was actually changed.
#' @keywords internal
transform_files <- function(files, transformers, include_roxygen_examples) {
  transformer <- make_transformer(transformers, include_roxygen_examples)
  max_char <- min(max(nchar(files), 0), getOption("width"))
  if (length(files) > 0L) {
    cat("Styling ", length(files), " files:\n")
  }

  changed <- map_lgl(files, transform_file,
    fun = transformer, max_char_path = max_char
  )
  communicate_summary(changed, max_char)
  communicate_warning(changed, transformers)
  tibble(file = files, changed = changed)
}

#' Transform a file and output a customized message
#'
#' Transforms file contents and outputs customized messages.
#' @param max_char_path The number of characters of the longest path. Determines
#'   the indention level of `message_after`.
#' @param message_before The message to print before the path.
#' @param message_after The message to print after the path.
#' @param message_after_if_changed The message to print after `message_after` if
#'   any file was transformed.
#' @inheritParams transform_utf8
#' @param ... Further arguments passed to [transform_utf8()].
#' @keywords internal
transform_file <- function(path,
                           fun,
                           max_char_path,
                           message_before = "",
                           message_after = " [DONE]",
                           message_after_if_changed = " *",
                           ...) {
  char_after_path <- nchar(message_before) + nchar(path) + 1
  max_char_after_message_path <- nchar(message_before) + max_char_path + 1
  n_spaces_before_message_after <-
    max_char_after_message_path - char_after_path
  cat(
    message_before, path,
    rep_char(" ", max(0L, n_spaces_before_message_after)),
    append = FALSE
  )
  changed <- transform_code(path, fun = fun, ...)

  bullet <- ifelse(is.na(changed), "warning", ifelse(changed, "info", "tick"))

  cli::cat_bullet(bullet = bullet)
  invisible(changed)
}

#' Closure to return a transformer function
#'
#' This function takes a list of transformer functions as input and
#' returns a function that can be applied to character strings
#' that should be transformed.
#' @param transformers A list of transformer functions that operate on flat
#'   parse tables.
#' @param include_roxygen_examples Whether or not to style code in roxygen
#'   examples.
#' @inheritParams parse_transform_serialize_r
#' @keywords internal
#' @importFrom purrr when
make_transformer <- function(transformers, include_roxygen_examples, warn_empty = TRUE) {
  force(transformers)
  function(text) {
    transformed_code <- text %>%
      parse_transform_serialize_r(transformers, warn_empty = warn_empty) %>%
      when(
        include_roxygen_examples ~
        parse_transform_serialize_roxygen(., transformers),
        ~.
      )
    transformed_code
  }
}

#' Parse, transform and serialize roxygen comments
#'
#' Splits `text` into roxygen code examples and non-roxygen code examples and
#' then maps over these examples by applying
#' [style_roxygen_code_example()].
#' @section Hierarchy:
#' Styling involves splitting roxygen example code into segments, and segments
#' into snippets. This describes the process for input of
#' [parse_transform_serialize_roxygen()]:
#'
#' - Splitting code into roxygen example code and other code. Downstream,
#'   we are only concerned about roxygen code. See
#'   [parse_transform_serialize_roxygen()].
#' - Every roxygen example code can have zero or more
#'   dontrun / dontshow / donttest sequences. We next create segments of roxygen
#'   code examples that contain at most one of these. See
#'   [style_roxygen_code_example()].
#' - We further split the segment that contains at most one dont* sequence into
#'   snippets that are either don* or not. See
#'   [style_roxygen_code_example_segment()].
#'
#' Finally, that we have roxygen code snippets that are either dont* or not,
#' we style them in [style_roxygen_example_snippet()] using
#' [parse_transform_serialize_r()].
#' @importFrom purrr map_at flatten_chr
#' @keywords internal
parse_transform_serialize_roxygen <- function(text, transformers) {
  roxygen_seqs <- identify_start_to_stop_of_roxygen_examples_from_text(text)
  if (length(roxygen_seqs) < 1L) {
    return(text)
  }
  split_segments <- split_roxygen_segments(text, unlist(roxygen_seqs))
  map_at(split_segments$separated, split_segments$selectors,
    style_roxygen_code_example,
    transformers = transformers
  ) %>%
    flatten_chr()
}

#' Split text into roxygen and non-roxygen example segments
#'
#' @param text Roxygen comments
#' @param roxygen_examples Integer sequence that indicates which lines in `text`
#'   are roxygen examples. Most conveniently obtained with
#'   [identify_start_to_stop_of_roxygen_examples_from_text].
#' @return
#' A list with two elements:
#'
#' * A list that contains elements grouped into roxygen and non-roxygen
#'   sections. This list is named `separated`.
#' * An integer vector with the indices that correspond to roxygen code
#'   examples in `separated`.
#' @importFrom rlang seq2
#' @keywords internal
split_roxygen_segments <- function(text, roxygen_examples) {
  if (is.null(roxygen_examples)) {
    return(lst(separated = list(text), selectors = NULL))
  }
  all_lines <- seq2(1L, length(text))
  active_segment <- as.integer(all_lines %in% roxygen_examples)
  segment_id <- cumsum(abs(c(0L, diff(active_segment)))) + 1L
  separated <- split(text, factor(segment_id))
  restyle_selector <- ifelse(roxygen_examples[1] == 1L, odd_index, even_index)

  lst(separated, selectors = restyle_selector(separated))
}

#' Parse, transform and serialize text
#'
#' Wrapper function for the common three operations.
#' @param warn_empty Whether or not a warning should be displayed when `text`
#'   does not contain any tokens.
#' @inheritParams compute_parse_data_nested
#' @inheritParams apply_transformers
#' @seealso [parse_transform_serialize_roxygen()]
#' @importFrom rlang abort
#' @keywords internal
parse_transform_serialize_r <- function(text, transformers, warn_empty = TRUE) {
  text <- assert_text(text)
  pd_nested <- compute_parse_data_nested(text)
  start_line <- find_start_line(pd_nested)
  if (nrow(pd_nested) == 0) {
    if (warn_empty) {
      warn("Text to style did not contain any tokens. Returning empty string.")
    }
    return("")
  }
  transformed_pd <- apply_transformers(pd_nested, transformers)
  flattened_pd <- post_visit(transformed_pd, list(extract_terminals)) %>%
    enrich_terminals(transformers$use_raw_indention) %>%
    apply_ref_indention() %>%
    set_regex_indention(
      pattern = transformers$reindention$regex_pattern,
      target_indention = transformers$reindention$indention,
      comments_only = transformers$reindention$comments_only
    )
  serialized_transformed_text <-
    serialize_parse_data_flattened(flattened_pd, start_line = start_line)

  if (can_verify_roundtrip(transformers)) {
    verify_roundtrip(text, serialized_transformed_text)
  }
  serialized_transformed_text
}

#' Apply transformers to a parse table
#'
#' The column `multi_line` is updated (after the line break information is
#' modified) and the rest of the transformers are applied afterwards,
#' The former requires two pre visits and one post visit.
#' @details
#' The order of the transformations is:
#'
#' * Initialization (must be first).
#' * Line breaks (must be before spacing due to indention).
#' * Update of newline and multi-line attributes (must not change afterwards,
#'   hence line breaks must be modified first).
#' * spacing rules (must be after line-breaks and updating newlines and
#'   multi-line).
#' * indention.
#' * token manipulation / replacement (is last since adding and removing tokens
#'   will invalidate columns token_after and token_before).
#' * Update indention reference (must be after line breaks).
#'
#' @param pd_nested A nested parse table.
#' @param transformers A list of *named* transformer functions
#' @importFrom purrr flatten
#' @keywords internal
apply_transformers <- function(pd_nested, transformers) {
  transformed_updated_multi_line <- post_visit(
    pd_nested,
    c(transformers$initialize, transformers$line_break, set_multi_line, update_newlines)
  )

  transformed_all <- pre_visit(
    transformed_updated_multi_line,
    c(transformers$space, transformers$indention, transformers$token)
  )

  transformed_absolute_indent <- context_to_terminals(
    transformed_all,
    outer_lag_newlines = 0L,
    outer_indent = 0L,
    outer_spaces = 0L,
    outer_indention_refs = NA
  )
  transformed_absolute_indent
}



#' Check whether a round trip verification can be carried out
#'
#' If scope was set to "line_breaks" or lower (compare [tidyverse_style()]),
#' we can compare the expression before and after styling and return an error if
#' it is not the same.
#' @param transformers The list of transformer functions used for styling.
#'   Needed for reverse engineering the scope.
#' @keywords internal
can_verify_roundtrip <- function(transformers) {
  is.null(transformers$token)
}

#' Verify the styling
#'
#' If scope was set to "line_breaks" or lower (compare [tidyverse_style()]),
#' we can compare the expression before and after styling and return an error if
#' it is not the same. Note that this method ignores comments and no
#' verification can be conducted if scope > "line_breaks".
#' @inheritParams expressions_are_identical
#' @importFrom rlang abort
#' @examples
#' styler:::verify_roundtrip("a+1", "a + 1")
#' styler:::verify_roundtrip("a+1", "a + 1 # comments are dropped")
#' \dontrun{
#' styler:::verify_roundtrip("a+1", "b - 3")
#' }
#' @keywords internal
verify_roundtrip <- function(old_text, new_text) {
  if (!expressions_are_identical(old_text, new_text)) {
    msg <- paste(
      "The expression evaluated before the styling is not the same as the",
      "expression after styling. This should not happen. Please file a",
      "bug report on GitHub (https://github.com/r-lib/styler/issues)",
      "using a reprex."
    )
    abort(msg)
  }
}

#' Check whether two expressions are identical
#'
#' @param old_text The initial expression in its character representation.
#' @param new_text The styled expression in its character representation.
#' @keywords internal
expressions_are_identical <- function(old_text, new_text) {
  identical(
    parse_safely(old_text, keep.source = FALSE),
    parse_safely(new_text, keep.source = FALSE)
  )
}
