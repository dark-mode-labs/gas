defmodule Gas.CollectionFilterTest do
  use ExUnit.Case, async: true
  alias Gas.StandardFilter

  @loc %Gas.Parser.Loc{line: 1, column: 1}

  describe "push filter" do
    test "push onto nil returns new list" do
      assert StandardFilter.apply("push", [nil, 1], @loc, []) == {:ok, [1]}
    end

    test "push onto list appends element" do
      assert StandardFilter.apply("push", [[1, 2], 3], @loc, []) == {:ok, [1, 2, 3]}
    end

    test "push onto non-list wraps and appends" do
      assert StandardFilter.apply("push", [1, 2], @loc, []) == {:ok, [1, 2]}
    end

    test "push with nil input leaves collection unchanged" do
      assert StandardFilter.apply("push", [[1], nil], @loc, []) == {:ok, [1]}
    end

    test "push with Gas.Literal.Empty input leaves collection unchanged" do
      assert StandardFilter.apply("push", [[1], %Gas.Literal.Empty{}], @loc, []) == {:ok, [1]}
    end

    test "push with Gas.Literal.Empty collection creates new list" do
      assert StandardFilter.apply("push", [%Gas.Literal.Empty{}, 1], @loc, []) == {:ok, [1]}
    end

    test "push onto a map wraps and appends" do
      assert StandardFilter.apply("push", [%{"a" => 1}, "x"], @loc, []) ==
               {:ok, [%{"a" => 1}, "x"]}
    end
  end
end
