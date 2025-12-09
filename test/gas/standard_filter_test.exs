defmodule Gas.StandardFilterTest do
  use ExUnit.Case, async: true
  alias Gas.StandardFilter
  doctest Gas.StandardFilter

  @loc %Gas.Parser.Loc{line: 1, column: 1}

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
               %Gas.WrongFilterArityError{
                 filter: "upcase",
                 loc: %Gas.Parser.Loc{column: 1, line: 1},
                 arity: 3,
                 expected_arity: "1"
               }
             }
    end

    test "filter not found" do
      assert StandardFilter.apply("no_filter_here", [1, 2, 3], @loc, []) ==
               {:error,
                %Gas.UndefinedFilterError{
                  filter: "no_filter_here",
                  loc: %Gas.Parser.Loc{line: 1, column: 1}
                }}
    end

    test "where filter test" do
      assert StandardFilter.apply(
               "where",
               [[%{"arg" => "Hi"}, %{"arg" => "Hello"}], "arg", "Hello"],
               @loc,
               []
             ) == {:ok, [%{"arg" => "Hello"}]}

      assert StandardFilter.apply(
               "where",
               [
                 [%{"name" => "Hello", "key" => "hello"}, %{"name" => "Null", "key" => nil}],
                 "key",
                 nil
               ],
               @loc,
               []
             ) == {:ok, [%{"key" => nil, "name" => "Null"}]}
    end

    test "sort filter test" do
      assert StandardFilter.apply(
               "sort",
               [[%{"arg" => "5"}, %{"arg" => "1"}, %{"arg" => "4"}, %{"arg" => "2"}], "arg"],
               @loc,
               []
             ) == {:ok, [%{"arg" => "1"}, %{"arg" => "2"}, %{"arg" => "4"}, %{"arg" => "5"}]}
    end
  end
end
