defmodule Gas.RangeTest do
  use ExUnit.Case, async: true

  alias Gas.{ParserContext, Range}
  alias Gas.Parser.Loc

  defp parse(template) do
    context = %ParserContext{rest: "{{#{template}}}", line: 1, column: 1, mode: :normal}
    {:ok, tokens, _context} = Gas.Lexer.tokenize_object(context)
    Range.parse(tokens)
  end

  @loc %Loc{line: 1, column: 1}

  describe "String.Chars impl" do
    test "to_string variables" do
      range = %Range{
        loc: @loc,
        start: %Gas.Variable{
          original_name: "first",
          loc: @loc,
          accesses: [],
          identifier: "first"
        },
        finish: %Gas.Variable{
          original_name: "limit",
          accesses: [],
          identifier: "limit",
          loc: @loc
        }
      }

      assert to_string(range) == "(first..limit)"
    end

    test "to_string literals" do
      range = %Range{
        loc: @loc,
        start: %Gas.Literal{loc: @loc, value: 1},
        finish: %Gas.Literal{value: 2, loc: @loc}
      }

      assert to_string(range) == "(1..2)"
    end
  end

  describe "parse/1" do
    test "range" do
      template = "(first..limit)"

      assert parse(template) == {
               :ok,
               %Gas.Range{
                 finish: %Gas.Variable{
                   original_name: "limit",
                   accesses: [],
                   identifier: "limit",
                   loc: %Loc{column: 11, line: 1}
                 },
                 loc: %Loc{column: 3, line: 1},
                 start: %Gas.Variable{
                   original_name: "first",
                   loc: %Loc{column: 4, line: 1},
                   accesses: [],
                   identifier: "first"
                 }
               },
               [end: %{column: 17, line: 1}]
             }
    end

    test "range literals" do
      template = "(1..5)"

      assert parse(template) == {
               :ok,
               %Gas.Range{
                 finish: %Gas.Literal{
                   loc: %Loc{column: 7, line: 1},
                   value: 5
                 },
                 loc: %Loc{column: 3, line: 1},
                 start: %Gas.Literal{loc: %Loc{column: 4, line: 1}, value: 1}
               },
               [end: %{column: 9, line: 1}]
             }
    end

    test "error" do
      template = "(1..15"

      assert parse(template) == {:error, "Range expected", %{line: 1, column: 3}}
    end
  end
end
