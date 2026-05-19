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

    test "populates interp_ast on literals inside {% case %}{% when %} branch bodies" do
      template =
        "{% case x %}{% when 'a' %}{% assign y = 'bg-{{ z }}' %}{% else %}{% assign y = 'plain' %}{% endcase %}"

      {:ok, parsed} = Gas.parse(template)
      expanded = Interpolation.expand(parsed, [])

      literals = collect_literals(expanded.parsed_template)
      interp_literal = Enum.find(literals, &(&1.value == "bg-{{ z }}"))

      assert interp_literal != nil, "expected to find the interpolated literal in the tree"
      assert %Template{} = interp_literal.interp_ast
    end

    test "populates interp_ast on literals inside {% if %}{% elsif %} branch bodies" do
      template =
        "{% if x %}a{% elsif y %}{% assign z = 'class-{{ w }}' %}{% endif %}"

      {:ok, parsed} = Gas.parse(template)
      expanded = Interpolation.expand(parsed, [])

      literals = collect_literals(expanded.parsed_template)
      interp_literal = Enum.find(literals, &(&1.value == "class-{{ w }}"))

      assert interp_literal != nil
      assert %Template{} = interp_literal.interp_ast
    end

    test "case/when interpolation renders correctly end-to-end (after expand/2)" do
      template_str = "{% case x %}{% when 'hit' %}{{ 'bg-{{ z }}' }}{% endcase %}"
      {:ok, parsed} = Gas.parse(template_str)
      expanded = Interpolation.expand(parsed, [])

      {:ok, result, _} = Gas.render(expanded, %{"x" => "hit", "z" => "red"})
      assert IO.iodata_to_binary(result) == "bg-red"
    end

    test "interpolation inside {% else %} body of case renders correctly" do
      template_str = "{% case s %}{% when 'unknown' %}a{% else %}{{ 'bg-{{ role }}' }}{% endcase %}"
      {:ok, parsed} = Gas.parse(template_str)
      expanded = Interpolation.expand(parsed, [])

      {:ok, result, _} =
        Gas.render(expanded, %{"s" => "missing-branch", "role" => "primary"})

      assert IO.iodata_to_binary(result) == "bg-primary"
    end

    test "interpolation in a literal under an AND child_condition (tuple field)" do
      template_str =
        "{% if x and y == 'lit-{{ name }}' %}got{% else %}miss{% endif %}"

      {:ok, parsed} = Gas.parse(template_str)
      expanded = Interpolation.expand(parsed, [])

      {:ok, result, _} =
        Gas.render(expanded, %{"x" => true, "y" => "lit-Bob", "name" => "Bob"})

      assert IO.iodata_to_binary(result) == "got"
    end

    test "elsif interpolation renders correctly end-to-end (after expand/2)" do
      template_str = "{% if false %}a{% elsif true %}{{ 'class-{{ w }}' }}{% endif %}"
      {:ok, parsed} = Gas.parse(template_str)
      expanded = Interpolation.expand(parsed, [])

      {:ok, result, _} = Gas.render(expanded, %{"w" => "primary"})
      assert IO.iodata_to_binary(result) == "class-primary"
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

    test "recurses into tuples" do
      vars = %{"pair" => {"plain", "with {{ x }}"}}
      normalized = Interpolation.normalize_vars(vars, [])

      assert %{"pair" => {"plain", %InterpolatedString{original: "with {{ x }}"}}} = normalized
    end
  end

  # Recursive Literal collector — walks every container type used in the AST
  # (list, map, struct, tuple) so regression tests can assert about literals
  # buried inside any nested position.
  defp collect_literals(node, acc \\ [])
  defp collect_literals(%Literal{} = lit, acc), do: [lit | acc]
  defp collect_literals(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_literals/2)

  defp collect_literals(%_struct{} = s, acc) do
    s |> Map.from_struct() |> Map.values() |> Enum.reduce(acc, &collect_literals/2)
  end

  defp collect_literals(map, acc) when is_map(map),
    do: Map.values(map) |> Enum.reduce(acc, &collect_literals/2)

  defp collect_literals(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &collect_literals/2)

  defp collect_literals(_, acc), do: acc
end
