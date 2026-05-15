defmodule Gas.BinaryConditionTest do
  use ExUnit.Case, async: true

  import Gas.BinaryCondition

  describe "eval/2" do
    test "numbers and comparison operators" do
      assert eval({1, :==, 1}) == {:ok, true}
      assert eval({1, :!=, 2}) == {:ok, true}
      assert eval({1, :<>, 2}) == {:ok, true}
      assert eval({1, :<, 2}) == {:ok, true}
      assert eval({2, :>, 1}) == {:ok, true}
      assert eval({1, :>=, 1}) == {:ok, true}
      assert eval({2, :>=, 1}) == {:ok, true}
      assert eval({1, :<=, 2}) == {:ok, true}
      assert eval({1, :<=, 1}) == {:ok, true}
      assert eval({1, :>, -2}) == {:ok, true}
      assert eval({-2, :<, 2}) == {:ok, true}
      assert eval({1.0, :>, -1.0}) == {:ok, true}
      assert eval({-1.0, :<, 1.0}) == {:ok, true}

      assert eval({1, :==, 2}) == {:ok, false}
      assert eval({1, :!=, 1}) == {:ok, false}
      assert eval({1, :<>, 1}) == {:ok, false}
      assert eval({1, :<, 0}) == {:ok, false}
      assert eval({2, :>, 4}) == {:ok, false}
      assert eval({1, :>=, 3}) == {:ok, false}
      assert eval({2, :>=, 4}) == {:ok, false}
      assert eval({1, :<=, 0}) == {:ok, false}
    end

    test "contains" do
      assert eval({"jose", :contains, "o"}) == {:ok, true}
      assert eval({"jose", :contains, "jose"}) == {:ok, true}

      assert eval({"jose", :contains, "john"}) == {:ok, false}
    end

    test "number and string" do
      assert eval({1, :<, "jose"}) == {:ok, false}
      assert eval({"jose", :<, 1}) == {:ok, false}

      assert eval({1, :==, "jose"}) == {:ok, false}

      assert eval({1.0, :<, "jose"}) == {:ok, false}
      assert eval({"jose", :<, 1.0}) == {:ok, false}
      assert eval({1.0, :==, "jose"}) == {:ok, false}
    end

    test "atom and string compare as their string forms" do
      assert eval({:delivery, :==, "delivery"}) == {:ok, true}
      assert eval({"delivery", :==, :delivery}) == {:ok, true}
      assert eval({:delivery, :==, "order_ahead"}) == {:ok, false}
      assert eval({:delivery, :!=, "order_ahead"}) == {:ok, true}
      assert eval({:delivery, :<>, "delivery"}) == {:ok, false}
    end

    test "nil / true / false are left alone (Liquid keeps boolean semantics)" do
      assert eval({true, :==, "true"}) == {:ok, false}
      assert eval({false, :==, "false"}) == {:ok, false}
      assert eval({nil, :==, "nil"}) == {:ok, false}
    end
  end
end
