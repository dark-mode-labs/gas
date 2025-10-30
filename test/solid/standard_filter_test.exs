defmodule Solid.StandardFilterTest do
  use ExUnit.Case, async: true
  alias Solid.StandardFilter
  doctest Solid.StandardFilter

  @loc %Solid.Parser.Loc{line: 1, column: 1}

  describe "apply/4" do
    test "basic filter" do
      assert StandardFilter.apply("upcase", ["ac"], @loc, []) == {:ok, "AC"}
    end

    test "argument error" do
      assert {:error, error} =
               StandardFilter.apply("base64_url_safe_decode", [1], @loc, [])

      assert error.message =~ "base64_url_safe_decode"
    end

    test "wrong arity" do
      assert StandardFilter.apply("upcase", ["ac", "extra", "arg"], @loc, []) == {
               :error,
               %Solid.WrongFilterArityError{
                 filter: "upcase",
                 loc: %Solid.Parser.Loc{column: 1, line: 1},
                 arity: 3,
                 expected_arity: "/1"
               }
             }
    end

    test "filter not found" do
      assert StandardFilter.apply("no_filter_here", [1, 2, 3], @loc, []) ==
               {:error,
                %Solid.UndefinedFilterError{
                  filter: "no_filter_here",
                  loc: %Solid.Parser.Loc{line: 1, column: 1}
                }}
    end
  end
end
