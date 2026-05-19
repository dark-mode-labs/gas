defmodule Gas.Compiler.ConstantFoldTest do
  use ExUnit.Case, async: true

  alias Gas.Compiler.ConstantFold

  defp render!(template_str, vars \\ %{}) do
    template_str
    |> Gas.parse!()
    |> ConstantFold.run()
    |> Gas.render!(vars)
    |> IO.iodata_to_binary()
  end

  describe "if with single-literal condition" do
    test "{% if true %} keeps body" do
      assert render!("{% if true %}yes{% else %}no{% endif %}") == "yes"
    end

    test "{% if false %} keeps else_body" do
      assert render!("{% if false %}yes{% else %}no{% endif %}") == "no"
    end

    test "{% if nil %} keeps else_body" do
      assert render!("{% if nil %}yes{% else %}no{% endif %}") == "no"
    end

    test "{% if 0 %} keeps body (numbers are truthy in Liquid)" do
      assert render!("{% if 0 %}yes{% else %}no{% endif %}") == "yes"
    end

    test "{% if 'hello' %} keeps body" do
      assert render!("{% if 'hello' %}yes{% else %}no{% endif %}") == "yes"
    end

    test "{% if false %} with no else returns empty" do
      assert render!("{% if false %}yes{% endif %}") == ""
    end
  end

  describe "unless with single-literal condition" do
    test "{% unless true %} keeps else_body" do
      assert render!("{% unless true %}yes{% else %}no{% endunless %}") == "no"
    end

    test "{% unless false %} keeps body" do
      assert render!("{% unless false %}yes{% else %}no{% endunless %}") == "yes"
    end
  end

  describe "non-literal conditions are not folded" do
    test "{% if dynamic %} is preserved and resolves at render time" do
      assert render!("{% if x %}yes{% else %}no{% endif %}", %{"x" => true}) == "yes"
      assert render!("{% if x %}yes{% else %}no{% endif %}", %{"x" => false}) == "no"
    end

    test "binary condition is preserved" do
      assert render!("{% if 1 == 1 %}yes{% else %}no{% endif %}") == "yes"
    end
  end

  describe "elsifs prevent folding" do
    test "if-with-elsif chain is preserved untouched even with literal outer condition" do
      template = "{% if true %}a{% elsif x %}b{% else %}c{% endif %}"
      assert render!(template, %{"x" => false}) == "a"
    end
  end
end
