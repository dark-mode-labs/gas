defmodule Gas.Compiler.InterpolationTest do
  use ExUnit.Case, async: true

  alias Gas.Compiler.Interpolation
  alias Gas.{InterpolatedString, Literal, Template, Variable}

  describe "expand/2 on the template parse tree" do
    test "populates interp_ast on string literals containing {{ }}" do
      {:ok, parsed} = Gas.parse(~s({% assign x = "hi {{ name }}" %}))
      expanded = Interpolation.expand(parsed, [])

      [%Gas.Tags.AssignTag{object: %Gas.Object{argument: %Literal{} = lit}}] =
        expanded.parsed_template

      assert lit.value == "hi {{ name }}"
      assert %Template{} = lit.interp_ast
    end

    test "leaves interp_ast nil for pure-text string literals" do
      {:ok, parsed} = Gas.parse(~s({% assign x = "plain text" %}))
      expanded = Interpolation.expand(parsed, [])

      [%Gas.Tags.AssignTag{object: %Gas.Object{argument: %Literal{} = lit}}] =
        expanded.parsed_template

      assert lit.interp_ast == nil
    end

    test "populates Variable.static_keys for all-literal access paths" do
      {:ok, parsed} = Gas.parse("{{ a.b.c }}")
      expanded = Interpolation.expand(parsed, [])

      [%Gas.Object{argument: %Variable{static_keys: keys}}] = expanded.parsed_template
      assert keys == ["a", "b", "c"]
    end

    test "leaves static_keys nil for variables with dynamic AccessVariable" do
      {:ok, parsed} = Gas.parse("{{ a[i] }}")
      expanded = Interpolation.expand(parsed, [])

      [%Gas.Object{argument: %Variable{static_keys: keys}}] = expanded.parsed_template
      assert keys == nil
    end

    test "is idempotent — running twice produces the same tree" do
      {:ok, parsed} = Gas.parse(~s(<h1>{{ name }}</h1>{% assign x = "{{ y }}" %}))
      once = Interpolation.expand(parsed, [])
      twice = Interpolation.expand(once, [])
      assert once == twice
    end
  end

  describe "normalize_vars/2 on the data side" do
    test "replaces binaries containing {{ }} with InterpolatedString sentinels" do
      vars = %{"greeting" => "hello {{ name }}"}
      normalized = Interpolation.normalize_vars(vars, [])

      assert %{"greeting" => %InterpolatedString{original: "hello {{ name }}"}} = normalized
    end

    test "leaves plain-text binaries untouched" do
      vars = %{"label" => "Order Now"}
      assert Interpolation.normalize_vars(vars, []) == %{"label" => "Order Now"}
    end

    test "recurses into nested maps" do
      vars = %{"a" => %{"b" => "v {{ x }}"}}
      normalized = Interpolation.normalize_vars(vars, [])

      assert %{"a" => %{"b" => %InterpolatedString{original: "v {{ x }}"}}} = normalized
    end

    test "recurses into lists" do
      vars = %{"items" => ["plain", "{{ x }}"]}
      normalized = Interpolation.normalize_vars(vars, [])

      assert %{"items" => ["plain", %InterpolatedString{original: "{{ x }}"}]} = normalized
    end

    test "leaves structs alone (e.g. Ecto schemas)" do
      now = NaiveDateTime.utc_now()
      vars = %{"now" => now}
      assert Interpolation.normalize_vars(vars, []) == %{"now" => now}
    end
  end
end
