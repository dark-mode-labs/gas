defmodule Gas.Tag do
  @moduledoc """
  manage all registered tags
  """
  alias Gas.{Lexer, ParserContext, Renderable, Tags}
  alias Gas.Parser.Loc

  @callback parse(
              tag_name :: binary,
              Loc.t(),
              ParserContext.t()
            ) ::
              {:ok, Renderable.t(), ParserContext.t()}
              | {:error, reason :: binary, Lexer.loc()}
              | {:error, reason :: binary, rest :: binary, Lexer.loc()}

  @doc """
  Nodes this tag is equivalent to, given the variables already bound at compile
  time, or `:error` to stay interpreted.

  A tag whose behaviour depends on a value the layout fixes can hand the
  compiler the tree it would have built, and be compiled like any other node.
  The replacement must render identically and is used for output only — context
  changes it makes are discarded, as `Gas.Renderable` implementations that
  render a sub-template discard theirs.
  """
  @callback gas_rewrite(tag :: struct, known :: map) :: {:ok, list} | :error

  @doc """
  Whether rendering this tag leaves the caller's variables untouched.

  Answering `true` keeps compile-time bindings alive across the tag when it has
  to be interpreted, so constants after it still fold.
  """
  @callback gas_assigns_nothing?() :: boolean

  @doc """
  Whether this tag reads values only the request can supply.

  A tag answering `true` is compiled to a call of its `Gas.Renderable`
  implementation instead of being handed back to the interpreter: what it does
  is fixed even though what it reads is not. Answer `true` only where
  `gas_rewrite/2` cannot succeed for want of a value, never to excuse a tag the
  compiler ought to understand.
  """
  @callback gas_renders_at_runtime?() :: boolean

  @optional_callbacks gas_rewrite: 2, gas_assigns_nothing?: 0, gas_renders_at_runtime?: 0

  def default_tags do
    %{
      "#" => Tags.InlineCommentTag,
      "assign" => Tags.AssignTag,
      "break" => Tags.BreakTag,
      "capture" => Tags.CaptureTag,
      "case" => Tags.CaseTag,
      "comment" => Tags.NoOpTag,
      "continue" => Tags.ContinueTag,
      "cycle" => Tags.CycleTag,
      "decrement" => Tags.CounterTag,
      "doc" => Tags.NoOpTag,
      "echo" => Tags.EchoTag,
      "for" => Tags.ForTag,
      "if" => Tags.IfTag,
      "increment" => Tags.CounterTag,
      "raw" => Tags.RawTag,
      "render" => Tags.RenderTag,
      "tablerow" => Tags.TablerowTag,
      "unless" => Tags.IfTag
    }
  end

  @spec parse(tag_name :: binary, Loc.t(), ParserContext.t()) ::
          {:ok, Renderable.t(), ParserContext.t()}
          | {:error, reason :: binary, Lexer.loc()}
          | {:error, reason :: binary, rest :: binary, Lexer.loc()}
  def parse(tag_name, loc, context) do
    module = (context.tags || default_tags())[tag_name]

    if module do
      module.parse(tag_name, loc, context)
    else
      {:error, "Unexpected tag '#{tag_name}'", %{line: loc.line, column: loc.column}}
    end
  end
end
