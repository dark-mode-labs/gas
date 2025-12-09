defmodule Gas.Tags.ContinueTagTest do
  use ExUnit.Case, async: true
  alias Gas.Tags.ContinueTag
  alias Gas.{Lexer, ParserContext}
  alias Gas.Parser.Loc

  defp parse(template) do
    context = %ParserContext{rest: template, line: 1, column: 1, mode: :normal}

    with {:ok, "continue", context} <- Lexer.tokenize_tag_start(context) do
      ContinueTag.parse("continue", %Loc{line: 1, column: 1}, context)
    end
  end

  describe "parse/2" do
    test "basic" do
      template = ~s<{% continue %}>

      assert parse(template) == {
               :ok,
               %ContinueTag{loc: %Loc{line: 1, column: 1}},
               %ParserContext{column: 15, line: 1, mode: :normal, rest: ""}
             }
    end

    test "error" do
      template = ~s<{% continue yo %}>
      assert parse(template) == {:error, "Unexpected token", %{column: 13, line: 1}}
    end

    test "unexpected character" do
      template = ~s<{% continue - %}>
      assert parse(template) == {:error, "Unexpected character '-'", %{column: 13, line: 1}}
    end
  end

  describe "Renderable impl" do
    test "continue exp" do
      template = ~s<{% continue %}>
      context = %Gas.Context{}

      {:ok, tag, _rest} = parse(template)

      assert catch_throw(Gas.Renderable.render(tag, context, [])) ==
               {:continue_exp, [], context}
    end
  end
end
