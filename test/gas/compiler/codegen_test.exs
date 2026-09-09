defmodule Gas.Compiler.CodegenTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gas.Compiler.Codegen

  defmodule SilentTag do
    defstruct [:loc]
    def gas_renders_nothing?, do: true

    defimpl Gas.Renderable do
      def render(_tag, context, _options), do: {[], context}
    end
  end

  defmodule RewritableTag do
    defstruct [:loc, :expression]

    def gas_rewrite(%__MODULE__{expression: expression}, known) do
      case Gas.Compiler.Codegen.constant_argument(expression, known) do
        {:ok, text} when is_binary(text) ->
          {:ok, elem(Gas.Parser.parse(text), 1)}

        _ ->
          :error
      end
    end

    defimpl Gas.Renderable do
      def render(tag, context, options) do
        case Gas.Argument.get(tag.expression, context, [], options) do
          {:ok, text, _ctx} when is_binary(text) ->
            {:ok, tree} = Gas.Parser.parse(text)
            {out, _inner} = Gas.render(tree, context, options)
            {out, context}

          _ ->
            {[], context}
        end
      end
    end
  end

  defmodule Opaque do
    defstruct [:x]
  end

  defmodule QuietTag do
    defstruct [:loc]

    def gas_assigns_nothing?, do: true

    defimpl Gas.Renderable do
      def render(_tag, context, _options), do: {["quiet"], context}
    end
  end

  defmodule LoudTag do
    defstruct [:loc]

    defimpl Gas.Renderable do
      def render(_tag, context, _options), do: {["loud"], context}
    end
  end

  defmodule TestTranslator do
    def translation, do: %{"greet" => "Hello {{ name }}"}
  end

  defmodule TestFileSystem do
    @behaviour Gas.FileSystem

    @impl true
    def read_template_file("greeting", _opts), do: {:ok, "Hi {{ name }}!"}
    def read_template_file("outer", _opts), do: {:ok, "[{% render 'greeting', name: who %}]"}
    def read_template_file("ctx", _opts), do: {:ok, "{{ context.item }}/{{ context.keep }}"}
    def read_template_file("each", _opts), do: {:ok, "<{{ each }}>"}

    def read_template_file("counted", _opts),
      do: {:ok, "{{ forloop.index }}/{{ forloop.length }} "}

    def read_template_file("bare", _opts), do: {:ok, "{{ thing }}"}
    def read_template_file("bad", _opts), do: {:ok, "{{ s | slice: n }}"}

    def read_template_file("mixed", _opts),
      do: {:ok, "{{ context.item }}/{{ context.keep }}/{{ extra }}"}

    def read_template_file(path, _opts),
      do: {:error, %Gas.FileSystem.Error{reason: "no such template #{path}"}}
  end

  # Two DIFFERENT data rows, because one row passes for a frozen runtime value.
  defp both(source, vars_a, vars_b \\ nil) do
    template = compiled_template(source)
    tree = template.parsed_template
    mod = Module.concat([Gas.CodegenCase, "M#{System.unique_integer([:positive])}"])
    {:ok, compiled} = Codegen.compile(tree, mod)

    check = fn vars ->
      # A filter error returns {:error, errors, result}; the partial is still the output.
      interpreted =
        case Gas.render(template, %Gas.Context{vars: vars}, []) do
          {:ok, result, _errors} -> result
          {:error, _errors, result} -> result
        end

      expected = IO.iodata_to_binary(interpreted)
      {rendered, _ctx} = compiled.render(%Gas.Context{vars: vars}, [])
      actual = IO.iodata_to_binary(rendered)

      assert actual == expected,
             "compiled output differs\nexpected: #{inspect(expected)}\nactual:   #{inspect(actual)}"

      expected
    end

    a = check.(vars_a)
    if vars_b, do: check.(vars_b)
    a
  end

  # Requires compiled and interpreted to agree for every row, errors included.
  defp compiled_matches(source, rows, opts) do
    interpreted = compiled_template(source, opts)
    {:ok, module} = Codegen.compile_cached(interpreted.parsed_template)
    compiled = %{interpreted | module: module}

    rows
    |> Enum.map(fn vars ->
      {expected_errors, expected} = outcome(interpreted, vars, opts)
      {actual_errors, actual} = outcome(compiled, vars, opts)
      assert actual == expected
      assert length(actual_errors) == length(expected_errors)
      expected
    end)
    |> List.first()
  end

  # The passes `Gas.precompile/2` runs, so the compiler sees production ASTs.
  defp compiled_template(source, opts \\ []) do
    {:ok, template} = Gas.parse(source)

    template
    |> Gas.Compiler.Interpolation.expand(opts)
    |> Gas.Compiler.ConstantFold.run()
    |> Gas.Compiler.TextMerge.run()
  end

  defp outcome(template, vars, opts) do
    case Gas.render(template, %Gas.Context{vars: vars}, opts) do
      {:ok, out, errors} -> {errors, IO.iodata_to_binary(out)}
      {:error, errors, out} -> {errors, IO.iodata_to_binary(out)}
    end
  end

  # `both/3` cannot tell compiled from fell-back; this fails on a silent fallback.
  defp assert_compiled(source, opts \\ []) do
    template = compiled_template(source, opts)
    {_src, _data, covered, total} = Codegen.source(template.parsed_template, Gas.CodegenCase.Cov)
    assert covered == total, "#{total - covered} of #{total} nodes fell back to the interpreter"
  end

  # A specialised module is valid only for these bindings, so both sides get them.
  defp both_known(source, known) do
    template = compiled_template(source)
    mod = Module.concat([Gas.CodegenCase, "K#{System.unique_integer([:positive])}"])
    {:ok, compiled} = Codegen.compile(template.parsed_template, mod, known)
    context = %Gas.Context{vars: known}

    expected =
      case Gas.render(template, context, []) do
        {:ok, result, _errors} -> IO.iodata_to_binary(result)
        {:error, _errors, result} -> IO.iodata_to_binary(result)
      end

    {rendered, _ctx} = compiled.render(context, [])
    assert IO.iodata_to_binary(rendered) == expected
    expected
  end

  # The module-level rescue would satisfy a parity assert by falling back, so check the log.
  defp half_settled(source, known, vars) do
    template = compiled_template(source)
    mod = Module.concat([Gas.CodegenCase, "H#{System.unique_integer([:positive])}"])
    {:ok, compiled} = Codegen.compile(template.parsed_template, mod, known)
    context = %Gas.Context{vars: Map.merge(known, vars)}

    {rendered, log} =
      with_log(fn ->
        {out, _ctx} = compiled.render(context, [])
        IO.iodata_to_binary(out)
      end)

    {interpreted, _ctx} = Gas.render(template.parsed_template, context, [])

    refute log =~ "renders interpreted from here",
           "the compiled form fell back to the interpreter"

    assert rendered == IO.iodata_to_binary(interpreted)
    rendered
  end

  defp specialised_source(source, known) do
    template = compiled_template(source)
    mod = Module.concat([Gas.CodegenCase, "Src#{System.unique_integer([:positive])}"])
    {src, _data, _covered, _total} = Codegen.source(template.parsed_template, mod, known)
    src
  end

  defp object(name) do
    %Gas.Object{
      loc: %Gas.Parser.Loc{line: 1, column: 1},
      argument: %Gas.Variable{
        loc: %Gas.Parser.Loc{line: 1, column: 1},
        identifier: name,
        accesses: [],
        original_name: name,
        static_keys: [name]
      },
      filters: []
    }
  end

  # Folding must not only happen, it must fold to what the interpreter renders.
  defp folded_output(tree, known) do
    mod = Module.concat([Gas.CodegenCase, "F#{System.unique_integer([:positive])}"])
    {:ok, compiled} = Codegen.compile(tree, mod, known)
    context = %Gas.Context{vars: known}

    {compiled_out, _ctx} = compiled.render(context, [])
    {interpreted_out, _ctx} = Gas.render(tree, context, [])

    assert IO.iodata_to_binary(compiled_out) == IO.iodata_to_binary(interpreted_out)
    IO.iodata_to_binary(compiled_out)
  end

  defp render_to_string(template, vars, opts) do
    {:ok, result, _errors} = Gas.render(template, vars, opts)
    IO.iodata_to_binary(result)
  end

  describe "text and interpolation" do
    test "static text" do
      assert both("<p>hello</p>", %{}) == "<p>hello</p>"
    end

    test "variable" do
      assert both("{{ name }}", %{"name" => "Ada"}, %{"name" => "Grace"}) == "Ada"
    end

    test "nested path" do
      vars = %{"a" => %{"b" => %{"c" => "deep"}}}
      assert both("{{ a.b.c }}", vars, %{"a" => %{"b" => %{"c" => "other"}}}) == "deep"
    end

    test "missing variable renders empty" do
      assert both("[{{ nope }}]", %{}) == "[]"
    end

    test "integer and boolean" do
      assert both("{{ n }}|{{ b }}", %{"n" => 42, "b" => true}, %{"n" => 7, "b" => false}) ==
               "42|true"
    end

    test "text longer than inspect's printable limit is not truncated" do
      text = String.duplicate("abcd", 3000)

      assert both(text <> "{{ x }}" <> text, %{"x" => "-"}, %{"x" => "+"}) ==
               text <> "-" <> text
    end

    test "a long string literal is not truncated" do
      value = String.duplicate("z", 9000)
      assert both("{% assign s = '#{value}' %}{{ s }}", %{}) == value
    end

    test "comment and doc render nothing and change nothing" do
      src =
        "{% assign x = 'v' %}[{% comment %}gone{% endcomment %}{% doc %}also{% enddoc %}{{ x }}]"

      assert_compiled(src)
      assert both(src, %{}) == "[v]"
    end

    test "list index access" do
      assert both("{{ xs[1] }}", %{"xs" => ["a", "b", "c"]}, %{"xs" => ["x", "y", "z"]}) == "b"
    end
  end

  describe "filters" do
    test "single filter" do
      assert both("{{ s | upcase }}", %{"s" => "abc"}, %{"s" => "def"}) == "ABC"
    end

    test "filter with argument" do
      assert both("{{ s | append: '!' }}", %{"s" => "hi"}, %{"s" => "yo"}) == "hi!"
    end

    test "chained filters" do
      assert both("{{ s | upcase | append: '.' }}", %{"s" => "ab"}, %{"s" => "cd"}) == "AB."
    end

    test "filter with named arguments" do
      Application.put_env(:gas, :translator, TestTranslator)
      on_exit(fn -> Application.delete_env(:gas, :translator) end)

      assert_compiled("{{ 'greet' | t: name: n }}")
      assert both("{{ 'greet' | t: name: n }}", %{"n" => "Ada"}, %{"n" => "Grace"}) == "Hello Ada"
    end

    test "filter with variable argument" do
      assert both("{{ a | append: b }}", %{"a" => "x", "b" => "y"}, %{"a" => "p", "b" => "q"}) ==
               "xy"
    end
  end

  describe "assign" do
    test "assign then use" do
      assert both("{% assign x = 'v' %}{{ x }}", %{}) == "v"
    end

    test "assign from a variable" do
      assert both("{% assign x = src %}{{ x }}", %{"src" => "a"}, %{"src" => "b"}) == "a"
    end

    test "reassignment wins" do
      assert both("{% assign x = 'one' %}{% assign x = 'two' %}{{ x }}", %{}) == "two"
    end

    test "assign from an interpolated literal" do
      assert both("{% assign x = 'a-{{ y }}-b' %}{{ x }}", %{"y" => "M"}, %{"y" => "N"}) ==
               "a-M-b"
    end

    test "accumulator across a conditional" do
      src = """
      {% assign xs = '' %}\
      {% assign xs = xs | append: 'a' %}\
      {% if flag %}{% assign xs = xs | append: 'b' %}{% endif %}\
      {% assign xs = xs | append: 'c' %}{{ xs }}\
      """

      assert both(src, %{"flag" => true}, %{"flag" => false}) == "abc"
    end
  end

  describe "conditionals" do
    test "if true and false" do
      assert both("{% if flag %}Y{% else %}N{% endif %}", %{"flag" => true}, %{"flag" => false}) ==
               "Y"
    end

    test "unless" do
      assert both("{% unless flag %}Y{% else %}N{% endunless %}", %{"flag" => false}, %{
               "flag" => true
             }) == "Y"
    end

    test "elsif chain" do
      src = "{% if n == 1 %}one{% elsif n == 2 %}two{% else %}many{% endif %}"
      assert_compiled(src)
      assert both(src, %{"n" => 2}, %{"n" => 9}) == "two"
    end

    test "comparison operators" do
      assert both("{% if n > 3 %}big{% else %}small{% endif %}", %{"n" => 5}, %{"n" => 1}) ==
               "big"
    end

    test "and / or" do
      src = "{% if a == 'x' and b == 'y' %}both{% else %}no{% endif %}"
      assert both(src, %{"a" => "x", "b" => "y"}, %{"a" => "x", "b" => "z"}) == "both"
    end

    test "an interpolated literal in a condition is left to the interpreter" do
      src = "{% if flag == 'a-{{ y }}-b' %}Y{% else %}N{% endif %}"
      vars = fn f -> %{"flag" => f, "y" => "M"} end

      template = compiled_template(src)

      {_source, _data, covered, total} =
        Codegen.source(template.parsed_template, Gas.CodegenCase.Cond)

      assert covered < total, "must not compile: a condition has nowhere to put a helper function"

      assert both(src, vars.("a-M-b"), vars.("other")) == "Y"
    end

    test "an interpolated literal as a bare condition is left to the interpreter" do
      assert both("{% if 'x{{ y }}' %}Y{% else %}N{% endif %}", %{"y" => "1"}, %{"y" => "2"}) ==
               "Y"
    end

    test "an interpolated literal in an elsif is left to the interpreter" do
      src = "{% if a %}A{% elsif b == 'v{{ y }}' %}B{% else %}C{% endif %}"
      vars = fn b -> %{"a" => false, "b" => b, "y" => "1"} end
      assert both(src, vars.("v1"), vars.("zz")) == "B"
    end

    test "a branch reassigning an earlier constant invalidates it" do
      src = "{% assign v = 'a' %}{% if flag %}{% assign v = 'b' %}{% endif %}[{{ v }}]"
      assert both(src, %{"flag" => false}, %{"flag" => true}) == "[a]"
    end

    test "a branch reassigning a twice-assigned constant invalidates it" do
      src =
        "{% assign v = 'a' %}{% assign v = 'a2' %}" <>
          "{% if flag %}{% assign v = 'b' %}{% endif %}[{{ v }}]"

      assert both(src, %{"flag" => true}, %{"flag" => false}) == "[b]"
    end

    test "a loop reassigning an earlier constant invalidates it" do
      src = "{% assign v = 'a' %}{% for i in xs %}{% assign v = i %}{% endfor %}[{{ v }}]"
      assert both(src, %{"xs" => ["p", "q"]}, %{"xs" => []}) == "[q]"
    end

    test "assign inside a branch is visible after it" do
      src = "{% if flag %}{% assign x = 'set' %}{% endif %}[{{ x }}]"
      assert both(src, %{"flag" => true}, %{"flag" => false}) == "[set]"
    end
  end

  describe "for" do
    test "simple loop" do
      assert both("{% for i in xs %}{{ i }},{% endfor %}", %{"xs" => ["a", "b"]}, %{"xs" => ["c"]}) ==
               "a,b,"
    end

    test "empty collection uses else" do
      assert both("{% for i in xs %}{{ i }}{% else %}none{% endfor %}", %{"xs" => []}, %{
               "xs" => ["a"]
             }) == "none"
    end

    test "missing collection uses else" do
      assert both("{% for i in nope %}{{ i }}{% else %}none{% endfor %}", %{}) == "none"
    end

    test "forloop metadata" do
      src =
        "{% for i in xs %}{{ forloop.index }}/{{ forloop.length }}{% if forloop.first %}F{% endif %}{% if forloop.last %}L{% endif %} {% endfor %}"

      assert both(src, %{"xs" => ["a", "b", "c"]}, %{"xs" => ["z"]}) == "1/3F 2/3 3/3L "
    end

    test "loop variable shadows an outer variable and is restored" do
      src = "{{ i }}|{% for i in xs %}{{ i }}{% endfor %}|{{ i }}"

      assert both(src, %{"i" => "out", "xs" => ["a", "b"]}, %{"i" => "z", "xs" => ["c"]}) ==
               "out|ab|out"
    end

    test "nested loops" do
      src = "{% for a in xs %}{% for b in ys %}{{ a }}{{ b }} {% endfor %}{% endfor %}"

      assert both(src, %{"xs" => ["1", "2"], "ys" => ["x", "y"]}, %{"xs" => ["9"], "ys" => ["q"]}) ==
               "1x 1y 2x 2y "
    end

    test "assign inside a loop accumulates" do
      src =
        "{% assign acc = '' %}{% for i in xs %}{% assign acc = acc | append: i %}{% endfor %}{{ acc }}"

      assert both(src, %{"xs" => ["a", "b", "c"]}, %{"xs" => ["z"]}) == "abc"
    end

    test "the outer forloop is readable again after an inner loop ends" do
      src = "{% for a in xs %}{% for b in ys %}{% endfor %}{{ forloop.index }}{% endfor %}"
      assert both(src, %{"xs" => ["p", "q"], "ys" => ["m"]}, %{"xs" => ["z"], "ys" => []}) == "12"
    end

    test "break keeps the output produced before it" do
      src = "{% for i in xs %}{{ i }}{% if i == 'b' %}{% break %}{% endif %}{% endfor %}"
      assert both(src, %{"xs" => ["a", "b", "c"]}, %{"xs" => ["z"]}) == "ab"
    end

    test "continue skips the rest of its iteration only" do
      src = "{% for i in xs %}[{% if i == 'b' %}{% continue %}{% endif %}{{ i }}]{% endfor %}"
      assert both(src, %{"xs" => ["a", "b", "c"]}, %{"xs" => ["z"]}) == "[a][[c]"
    end

    test "break inside a nested loop leaves the outer loop running" do
      src =
        "{% for a in xs %}{% for b in ys %}{{ b }}{% if b == 'q' %}{% break %}{% endif %}" <>
          "{% endfor %}|{% endfor %}"

      assert both(src, %{"xs" => ["1", "2"], "ys" => ["p", "q", "r"]}, %{
               "xs" => ["9"],
               "ys" => ["z"]
             }) ==
               "pq|pq|"
    end

    test "loop parameters are left to the interpreter" do
      src = "{% for i in xs limit: 2 %}{{ i }}{% endfor %}"
      assert both(src, %{"xs" => ["a", "b", "c"]}, %{"xs" => ["z"]}) == "ab"
    end

    test "a reversed loop is left to the interpreter" do
      src = "{% for i in xs reversed %}{{ i }}{% endfor %}"
      assert both(src, %{"xs" => ["a", "b", "c"]}, %{"xs" => ["z"]}) == "cba"
    end

    test "loop over a map" do
      assert both("{% for i in xs %}.{% endfor %}", %{"xs" => %{"a" => 1}}, %{"xs" => %{}}) == "."
    end
  end

  describe "interpolated settings" do
    # Only a coverage assertion catches this: the rescue keeps output correct either way.
    test "a compiled read renders a setting that carried liquid" do
      {:ok, ast} = Gas.parse("{{ x }}!")
      interpolated = %Gas.InterpolatedString{ast: ast, original: "{{ x }}!"}
      context = %Gas.Context{vars: %{"x" => "VALUE"}}

      assert Gas.Compiler.Runtime.resolve(interpolated, context, []) == "VALUE!"
    end

    test "it uses the setting's own compiled module when it has one" do
      # module and tree deliberately disagree, so the output names which ran
      {:ok, compiled_from} = Gas.parse("FROM-MODULE")
      {:ok, module} = Codegen.compile_cached(compiled_from.parsed_template)
      {:ok, other} = Gas.parse("FROM-TREE")

      interpolated = %Gas.InterpolatedString{ast: %{other | module: module}, original: "x"}

      assert Gas.Compiler.Runtime.resolve(interpolated, %Gas.Context{}, []) == "FROM-MODULE"
    end

    test "an ordinary value passes through untouched" do
      assert Gas.Compiler.Runtime.resolve("plain", %Gas.Context{}, []) == "plain"
      assert Gas.Compiler.Runtime.resolve(42, %Gas.Context{}, []) == 42
    end

    test "a template reading an interpolated setting renders it, not the struct" do
      template = compiled_template("[{{ s.content }}]")
      {:ok, module} = Codegen.compile_cached(template.parsed_template)

      vars =
        Gas.Compiler.Interpolation.normalize_vars(
          %{"s" => %{"content" => "{{ x }}!"}, "x" => "VALUE"},
          []
        )

      {out, _ctx} = module.render(%Gas.Context{vars: vars}, [])
      assert IO.iodata_to_binary(out) == "[VALUE!]"
    end
  end

  describe "dynamic access" do
    test "a variable key" do
      vars = fn k -> %{"m" => %{"a" => "A", "b" => "B"}, "k" => k} end
      assert_compiled("{{ m[k] }}")
      assert both("{{ m[k] }}", vars.("a"), vars.("b")) == "A"
    end

    test "a variable key assigned then used" do
      src = "{% assign v = m[k] %}{{ v }}"
      vars = fn k -> %{"m" => %{"a" => "A", "b" => "B"}, "k" => k} end
      assert_compiled(src)
      assert both(src, vars.("a"), vars.("b")) == "A"
    end

    test "two variable keys in one path" do
      vars = fn k -> %{"m" => %{"x" => %{"y" => "deep"}}, "j" => "x", "k" => k} end
      assert_compiled("{{ m[j][k] }}")
      assert both("{{ m[j][k] }}", vars.("y"), vars.("nope")) == "deep"
    end

    test "a variable key mixed with a literal segment" do
      vars = fn k -> %{"m" => %{"a" => %{"n" => "hit"}}, "k" => k} end
      assert_compiled("{{ m[k].n }}")
      assert both("{{ m[k].n }}", vars.("a"), vars.("zz")) == "hit"
    end

    test "a missing variable key renders empty" do
      assert_compiled("[{{ m[k] }}]")
      assert both("[{{ m[k] }}]", %{"m" => %{"a" => 1}, "k" => "zz"}) == "[]"
    end

    test "the loop variable as a key" do
      src = "{% for k in ks %}{{ m[k] }}{% endfor %}"
      vars = %{"m" => %{"a" => "1", "b" => "2"}, "ks" => ["a", "b"]}
      assert_compiled(src)
      assert both(src, vars, %{vars | "ks" => ["b"]}) == "12"
    end
  end

  describe "case" do
    test "matching when and else" do
      src = "{% case n %}{% when 1 %}one{% when 2 %}two{% else %}many{% endcase %}"
      assert both(src, %{"n" => 2}, %{"n" => 9}) == "two"
    end

    test "no clause matches and there is no else" do
      assert_compiled("[{% case n %}{% when 1 %}one{% endcase %}]")
      assert both("[{% case n %}{% when 1 %}one{% endcase %}]", %{"n" => 5}, %{"n" => 1}) == "[]"
    end

    test "one when with several values" do
      src = "{% case s %}{% when 'a' or 'b' %}hit{% else %}miss{% endcase %}"
      assert_compiled(src)
      assert both(src, %{"s" => "b"}, %{"s" => "c"}) == "hit"
    end

    test "an assign inside a branch survives the case" do
      src = "{% case n %}{% when 1 %}{% assign x = 'set' %}{% endcase %}[{{ x }}]"
      assert_compiled(src)
      assert both(src, %{"n" => 1}, %{"n" => 2}) == "[set]"
    end

    test "when uses liquid equality, not Erlang equality" do
      src = "{% case x %}{% when '' %}empty{% else %}full{% endcase %}"
      assert_compiled(src)
      assert both(src, %{}, %{"x" => "a"}) == "empty"
    end

    test "the subject is a path, matched against a variable" do
      src = "{% case a.b %}{% when target %}Y{% else %}N{% endcase %}"
      vars = fn t -> %{"a" => %{"b" => "v"}, "target" => t} end
      assert_compiled(src)
      assert both(src, vars.("v"), vars.("other")) == "Y"
    end
  end

  describe "liquid semantics that are not Elixir semantics" do
    test "empty string equals nil" do
      assert both("{% if x == '' %}Y{% else %}N{% endif %}", %{}, %{"x" => "a"}) == "Y"
    end

    test "blank" do
      assert both("{% if x == blank %}Y{% else %}N{% endif %}", %{"x" => []}, %{"x" => "a"}) ==
               "Y"
    end

    test "number compared with a numeric string" do
      assert both("{% if n > '3' %}Y{% else %}N{% endif %}", %{"n" => 5}, %{"n" => 1}) == "Y"
    end

    test "contains on a string and on a list" do
      src = "{% if s contains 'ell' %}S{% endif %}{% if xs contains 'b' %}L{% endif %}"

      assert both(src, %{"s" => "hello", "xs" => ["a", "b"]}, %{"s" => "hi", "xs" => ["c"]}) ==
               "SL"
    end

    test "not equal against nil" do
      assert both("{% if x != nil %}Y{% else %}N{% endif %}", %{"x" => "a"}, %{}) == "Y"
    end

    test "size on a map and on a list" do
      assert both("{{ m.size }}/{{ xs.size }}", %{"m" => %{"a" => 1}, "xs" => [1, 2]}, %{
               "m" => %{},
               "xs" => []
             }) == "1/2"
    end

    test "a filter that raises renders the interpreter's error message" do
      assert both("{{ s | slice: n }}", %{"s" => "abc", "n" => "x"}, %{"s" => "abc", "n" => 1}) =~
               "Filter: slice"
    end

    test "loop over a scalar iterates once" do
      assert both("{% for i in x %}[{{ i }}]{% endfor %}", %{"x" => "solo"}, %{"x" => 7}) ==
               "[solo]"
    end

    test "loop over a range" do
      src = "{% for i in (1..3) %}{{ i }}{% endfor %}"
      assert_compiled(src)
      assert both(src, %{}) == "123"
    end

    test "loop over a range with variable bounds" do
      src = "{% for i in (a..b) %}{{ i }}.{% endfor %}"
      assert_compiled(src)
      assert both(src, %{"a" => 1, "b" => 3}, %{"a" => 2, "b" => 2}) == "1.2.3."
    end

    test "a range bound that is not a number behaves as zero" do
      src = "{% for i in (a..b) %}{{ i }}.{% endfor %}"
      assert both(src, %{"a" => "x", "b" => 2}, %{"a" => 0, "b" => 1}) == "0.1.2."
    end

    test "a compiled loop leaves the register a later offset:continue reads" do
      src =
        "{% for i in xs %}{{ i }}{% endfor %}|{% for i in xs offset: continue %}{{ i }}{% endfor %}"

      assert both(src, %{"xs" => ["a", "b"]}, %{"xs" => ["c"]}) == "ab|"
    end
  end

  describe "capture" do
    test "captures rendered output" do
      assert both("{% capture c %}a{{ x }}b{% endcapture %}[{{ c }}]", %{"x" => "-"}, %{
               "x" => "+"
             }) == "[a-b]"
    end

    test "an assign made inside the capture survives it" do
      src = "{% capture c %}{% assign x = src %}{% endcapture %}[{{ x }}]"
      assert both(src, %{"src" => "A"}, %{"src" => "B"}) == "[A]"
    end

    test "the captured value is a binary, not iodata" do
      src = "{% capture c %}{% for i in xs %}{{ i }}{% endfor %}{% endcapture %}{{ c | size }}"
      assert both(src, %{"xs" => ["a", "b", "c"]}, %{"xs" => ["z"]}) == "3"
    end
  end

  describe "precompile wiring" do
    setup do
      %{opts: [file_system: {TestFileSystem, nil}]}
    end

    test "codegen: true attaches a module and renders identically", %{opts: opts} do
      {:ok, interpreted} = Gas.precompile("outer", opts)
      {:ok, compiled} = Gas.precompile("outer", [codegen: true] ++ opts)

      assert interpreted.module == nil
      assert compiled.module != nil

      for who <- ["Ada", "Grace"] do
        assert render_to_string(compiled, %{"who" => who}, opts) ==
                 render_to_string(interpreted, %{"who" => who}, opts)
      end

      assert render_to_string(compiled, %{"who" => "Ada"}, opts) == "[Hi Ada!]"
    end

    test "the partial reached through render is compiled too", %{opts: opts} do
      {:ok, _outer} = Gas.precompile("outer", [codegen: true] ++ opts)
      {:ok, partial} = Gas.precompile("greeting", [codegen: true] ++ opts)

      assert partial.module != nil
      assert function_exported?(partial.module, :render, 2)
    end

    test "a template cached before codegen was on is compiled on the next call", %{opts: opts} do
      cached = [cache_module: Gas.Caching.EtsCache] ++ opts

      {:ok, plain} = Gas.precompile("greeting", cached)
      assert plain.module == nil

      {:ok, compiled} = Gas.precompile("greeting", [codegen: true] ++ cached)
      assert compiled.module != nil

      {:ok, again} = Gas.precompile("greeting", [codegen: true] ++ cached)
      assert again.module == compiled.module

      # written back, so later hits do not re-derive the module from the tree
      assert {:ok, %Gas.Template{module: module}} = Gas.Caching.EtsCache.get("greeting")
      assert module == compiled.module

      assert render_to_string(compiled, %{"name" => "Ada"}, opts) == "Hi Ada!"
    end

    test "the same tree reuses one module", %{opts: opts} do
      {:ok, first} = Gas.precompile("greeting", [codegen: true] ++ opts)
      {:ok, second} = Gas.precompile("greeting", [codegen: true] ++ opts)

      assert first.module == second.module
    end

    test "dotted arguments merge onto the outer value", %{opts: opts} do
      src = "{% render 'ctx', context.item: chosen %}"
      vars = fn item -> %{"context" => %{"keep" => "K", "item" => "OLD"}, "chosen" => item} end

      assert compiled_matches(src, [vars.("A"), vars.("B")], opts) == "A/K"
      assert_compiled(src, opts)
    end

    test "with ... as binds one variable", %{opts: opts} do
      src = "{% render 'bare' with src as thing %}"
      assert compiled_matches(src, [%{"src" => "P"}, %{"src" => "Q"}], opts) == "P"
      assert_compiled(src, opts)
    end

    test "plain and dotted arguments both reach the partial", %{opts: opts} do
      src = "{% render 'mixed', context.item: chosen, extra: e %}"
      vars = fn n -> %{"context" => %{"keep" => "K"}, "chosen" => "I#{n}", "e" => "E#{n}"} end

      assert compiled_matches(src, [vars.(1), vars.(2)], opts) == "I1/K/E1"
      assert_compiled(src, opts)
    end

    test "an error inside the partial reaches the caller", %{opts: opts} do
      src = "[{% render 'bad', s: s, n: n %}]"
      vars = %{"s" => "abc", "n" => "x"}

      {errors, out} =
        outcome(
          %{compiled_template("[{% render 'bad', s: s, n: n %}]", opts) | module: nil},
          vars,
          opts
        )

      assert errors != [], "the interpreter must report the partial's filter error"
      assert out =~ "Filter: slice"
      assert compiled_matches(src, [vars], opts) =~ "Filter: slice"
    end

    test "render for: iterates the callee once per element", %{opts: opts} do
      src = "{% render 'each' for xs as each %}"
      assert compiled_matches(src, [%{"xs" => ["a", "b"]}, %{"xs" => ["c"]}], opts) == "<a><b>"
    end

    test "render for: over a non-list renders once", %{opts: opts} do
      src = "{% render 'each' for xs as each %}"
      assert compiled_matches(src, [%{"xs" => "solo"}, %{"xs" => "other"}], opts) == "<solo>"
    end

    test "render for: exposes forloop to the callee", %{opts: opts} do
      src = "{% render 'counted' for xs as each %}"
      assert compiled_matches(src, [%{"xs" => ["a", "b"]}, %{"xs" => ["z"]}], opts) == "1/2 2/2 "
    end

    test "a missing template records the tag's error", %{opts: opts} do
      src = "[{% render 'nope' %}]"
      assert compiled_matches(src, [%{}], opts) == "[]"
    end

    test "a strict-variables context is interpreted, errors and all", %{opts: opts} do
      {:ok, compiled} = Gas.precompile("greeting", [codegen: true] ++ opts)

      assert {:error, [%Gas.UndefinedVariableError{}], result} =
               Gas.render(compiled, %{}, [strict_variables: true] ++ opts)

      assert IO.iodata_to_binary(result) == "Hi !"
    end
  end

  describe "coverage reporting" do
    test "source/2 reports how much compiled" do
      t = compiled_template("{{ a }}{% if b %}x{% endif %}")
      {src, _data, covered, total} = Codegen.source(t.parsed_template, Gas.CodegenCase.Cov)
      assert covered == total
      assert src =~ "def render("
    end

    test "an uncovered node still renders correctly via fallback" do
      # increment uses counter_vars, which the compiler does not model
      assert both("{% increment c %}{% increment c %}", %{}) == "01"
    end

    test "a compiled read sees a counter written by an uncovered node" do
      assert both("{% increment c %}{% increment c %}|{{ c }}", %{}) == "01|2"
    end

    test "an assign target keeps its original name, not its identifier" do
      assert both("{% assign a.b = 'v' %}[{{ a }}]", %{}) == "[]"
    end

    test "a module that cannot be built reports :error instead of raising" do
      # A value with no source representation, so the render degrades instead of dying.
      tree = [%Gas.Object{argument: %Gas.Literal{value: self(), loc: nil}, filters: [], loc: nil}]

      assert Codegen.compile(tree, Gas.CodegenCase.Unbuildable) == :error
    end

    test "a tag declaring it renders nothing is compiled away" do
      tree = [
        %Gas.Text{text: "a", loc: nil},
        %SilentTag{loc: nil},
        %Gas.Text{text: "b", loc: nil}
      ]

      {_src, _data, covered, total} = Codegen.source(tree, Gas.CodegenCase.Silent)
      assert covered == total

      mod = Module.concat([Gas.CodegenCase, "S#{System.unique_integer([:positive])}"])
      {:ok, compiled} = Codegen.compile(tree, mod)
      {out, _ctx} = compiled.render(%Gas.Context{}, [])
      assert IO.iodata_to_binary(out) == "ab"
    end

    test "a filter called at the wrong arity is left to the interpreter" do
      t = compiled_template("{{ s | upcase: 1 }}")
      {_src, _data, covered, total} = Codegen.source(t.parsed_template, Gas.CodegenCase.Arity)
      assert {covered, total} == {0, 1}
    end
  end

  describe "specialisation" do
    test "a case over a bound subject picks its branch at compile time" do
      source =
        "{% case icon %}{% when 'star' %}STAR{% when 'bag' %}BAG{% else %}NONE{% endcase %}"

      known = %{"icon" => "bag"}

      assert both_known(source, known) == "BAG"

      generated = specialised_source(source, known)
      refute generated =~ "compare(sub", "a bound subject must not leave a runtime comparison"
      refute generated =~ "STAR", "a branch that cannot be reached must not be generated"
    end

    test "a case over an unbound subject keeps its runtime comparison" do
      source = "{% case icon %}{% when 'star' %}STAR{% else %}NONE{% endcase %}"

      assert both(source, %{"icon" => "star"}, %{"icon" => "other"}) == "STAR"
      assert specialised_source(source, %{}) =~ "compare(sub"
    end

    test "a case falls through to else when no bound when matches" do
      source = "{% case icon %}{% when 'star' %}STAR{% else %}NONE{% endcase %}"

      assert both_known(source, %{"icon" => "bag"}) == "NONE"
      refute specialised_source(source, %{"icon" => "bag"}) =~ "STAR"
    end

    test "a when listing several values matches any of them" do
      source = "{% case icon %}{% when 'star', 'bag' %}HIT{% else %}NONE{% endcase %}"

      assert both_known(source, %{"icon" => "bag"}) == "HIT"
      assert both_known(source, %{"icon" => "star"}) == "HIT"
      assert both_known(source, %{"icon" => "other"}) == "NONE"
    end

    test "a bound condition drops the branch it rules out" do
      source = "{% if flag %}YES{% else %}NO{% endif %}"

      assert both_known(source, %{"flag" => false}) == "NO"
      refute specialised_source(source, %{"flag" => false}) =~ "YES"
    end

    test "an empty bound list renders the else body" do
      source = "{% for item in items %}X{{ item }}{% else %}EMPTY{% endfor %}"

      assert both_known(source, %{"items" => []}) == "EMPTY"

      refute specialised_source(source, %{"items" => []}) =~ ~r/fp\d+ =/,
             "an else-only loop must not save a forloop it never restores"
    end

    test "every generated function is reachable" do
      source = """
      {% case icon %}{% when 'star' %}STAR{% else %}{{ other }}{% endcase %}
      {% if flag %}{{ a }}{% else %}{{ b }}{% endif %}
      {% for item in items %}{{ item }}{% endfor %}
      """

      generated = specialised_source(source, %{"icon" => "star", "flag" => true, "items" => []})

      for [_, name] <- Regex.scan(~r/defp (b\d+)\(/, generated) do
        references = length(Regex.scan(~r/\b#{name}\(/, generated))

        assert references > 1, "#{name} is defined but nothing calls it"
      end
    end
  end

  describe "a condition the bindings only half settle" do
    test "a settled operand emits its answer, the other still reads at runtime" do
      source = "{% if flag and user %}both{% else %}one{% endif %}"
      known = %{"flag" => true}

      assert half_settled(source, known, %{"user" => "ada"}) == "both"
      assert half_settled(source, known, %{}) == "one"

      # `truthy/1` is also defined in every generated module, so match the call site.
      generated = specialised_source(source, known)
      assert generated =~ "(true and", "a settled operand must emit its answer"
      refute generated =~ "(truthy(true)", "a settled operand must not compile to a call"
      assert generated =~ "truthy(get(", "the unsettled operand must still be read"
    end

    test "a settled operand that decides an `and` still agrees with the interpreter" do
      source = "{% if flag and user %}both{% else %}one{% endif %}"
      known = %{"flag" => false}

      assert half_settled(source, known, %{"user" => "ada"}) == "one"
      assert specialised_source(source, known) =~ "(false and"
    end

    test "an `or` folds its settled half the same way" do
      source = "{% if flag or user %}either{% else %}neither{% endif %}"
      known = %{"flag" => false}

      assert half_settled(source, known, %{"user" => "ada"}) == "either"
      assert half_settled(source, known, %{}) == "neither"
      assert specialised_source(source, known) =~ "(false or"
    end

    test "an elsif whose test is settled folds too" do
      source = "{% if a %}A{% elsif flag and user %}B{% else %}C{% endif %}"
      known = %{"flag" => true}

      assert half_settled(source, known, %{"user" => "ada"}) == "B"
      assert half_settled(source, known, %{"a" => "yes"}) == "A"
      assert half_settled(source, known, %{}) == "C"

      generated = specialised_source(source, known)
      assert generated =~ "(true and"
      refute generated =~ "(truthy(true)"
    end
  end

  describe "tags that participate in compilation" do
    test "a tag rewrites itself into nodes the compiler can take" do
      tag = %RewritableTag{
        loc: %Gas.Parser.Loc{line: 1, column: 1},
        expression: %Gas.Variable{
          loc: %Gas.Parser.Loc{line: 1, column: 1},
          identifier: "phrase",
          accesses: [],
          original_name: "phrase",
          static_keys: ["phrase"]
        }
      }

      tree = [tag]
      known = %{"phrase" => "{{ name }}!"}
      context = %Gas.Context{vars: Map.put(known, "name", "Ada")}

      mod = Module.concat([Gas.CodegenCase, "RW#{System.unique_integer([:positive])}"])
      {_src, _data, covered, total} = Codegen.source(tree, mod, known)
      assert covered == total, "a rewritten tag must not count as a fallback"

      {:ok, compiled} = Codegen.compile(tree, mod, known)
      {out, _ctx} = compiled.render(context, [])
      {expected, _ctx} = Gas.render(tree, context, [])

      assert IO.iodata_to_binary(out) == IO.iodata_to_binary(expected)
      assert IO.iodata_to_binary(out) == "Ada!"
    end

    test "a tag that cannot rewrite itself stays interpreted" do
      tag = %RewritableTag{
        loc: %Gas.Parser.Loc{line: 1, column: 1},
        expression: %Gas.Variable{
          loc: %Gas.Parser.Loc{line: 1, column: 1},
          identifier: "phrase",
          accesses: [],
          original_name: "phrase",
          static_keys: ["phrase"]
        }
      }

      {_src, _data, covered, total} = Codegen.source([tag], Gas.CodegenCase.RWNone, %{})
      assert covered < total

      mod = Module.concat([Gas.CodegenCase, "RWI#{System.unique_integer([:positive])}"])
      {:ok, compiled} = Codegen.compile([tag], mod, %{})
      context = %Gas.Context{vars: %{"phrase" => "{{ name }}!", "name" => "Ada"}}
      {out, _ctx} = compiled.render(context, [])

      assert IO.iodata_to_binary(out) == "Ada!"
    end

    test "constants survive an interpreted tag that assigns nothing" do
      tree = [%QuietTag{loc: %Gas.Parser.Loc{line: 1, column: 1}}, object("greeting")]
      known = %{"greeting" => "hello"}

      {src, _data, _covered, _total} = Codegen.source(tree, Gas.CodegenCase.Quiet, known)

      assert src =~ ~s("hello"), "the constant after the tag must still fold"
      assert folded_output(tree, known) == "quiethello"
    end

    test "constants do not survive an interpreted tag that may assign" do
      tree = [%LoudTag{loc: %Gas.Parser.Loc{line: 1, column: 1}}, object("greeting")]
      known = %{"greeting" => "hello"}

      {src, _data, _covered, _total} = Codegen.source(tree, Gas.CodegenCase.Loud, known)

      refute src =~ ~s("hello"), "a tag that may assign must invalidate the binding"
      assert folded_output(tree, known) == "loudhello"
    end
  end

  describe "a compiled render that raises" do
    test "reports the fallback instead of degrading silently" do
      tree = [object("thing")]
      mod = Module.concat([Gas.CodegenCase, "Raise#{System.unique_integer([:positive])}"])
      {:ok, compiled} = Codegen.compile(tree, mod)
      context = %Gas.Context{vars: %{"thing" => %Opaque{x: 1}}}

      log =
        capture_log(fn ->
          assert_raise Protocol.UndefinedError, fn -> compiled.render(context, []) end
        end)

      assert log =~ "renders interpreted from here"
      assert log =~ inspect(mod)
    end

    test "reports once per module, since a raising template raises every time" do
      tree = [object("thing")]
      mod = Module.concat([Gas.CodegenCase, "Once#{System.unique_integer([:positive])}"])
      {:ok, compiled} = Codegen.compile(tree, mod)
      context = %Gas.Context{vars: %{"thing" => %Opaque{x: 1}}}

      raise_once = fn ->
        capture_log(fn ->
          assert_raise Protocol.UndefinedError, fn -> compiled.render(context, []) end
        end)
      end

      assert raise_once.() =~ "renders interpreted from here"
      refute raise_once.() =~ "renders interpreted from here"
    end

    test "a render that does not raise stays quiet" do
      tree = [object("thing")]
      mod = Module.concat([Gas.CodegenCase, "Quiet#{System.unique_integer([:positive])}"])
      {:ok, compiled} = Codegen.compile(tree, mod)
      context = %Gas.Context{vars: %{"thing" => "fine"}}

      log = capture_log(fn -> compiled.render(context, []) end)

      refute log =~ "renders interpreted from here"
    end
  end

  describe "the compiled-module limit" do
    test "past the limit a tree is left to the interpreter" do
      template = compiled_template("{{ name }}!")

      assert :error =
               Codegen.compile_cached(template.parsed_template, %{}, module_limit: 0)
    end

    test "a setting whose template is past the limit still renders" do
      opts = [codegen: true, module_limit: 0]
      template = compiled_template("{{ greeting }}", opts)

      vars =
        Gas.Compiler.Interpolation.normalize_vars(
          %{"greeting" => "hi {{ name }}", "name" => "Ada"},
          opts
        )

      assert %Gas.InterpolatedString{ast: %Gas.Template{module: nil}} = vars["greeting"]

      {:ok, out, _errors} = Gas.render(template, %Gas.Context{vars: vars}, [])

      assert IO.iodata_to_binary(out) == "hi Ada"
    end

    test "under the limit the same tree still reuses one module" do
      template = compiled_template("{{ name }}?")
      tree = template.parsed_template

      assert {:ok, first} = Codegen.compile_cached(tree, %{}, module_limit: 1_000_000)
      assert {:ok, ^first} = Codegen.compile_cached(tree, %{}, module_limit: 1_000_000)
    end
  end

  describe "fetch_or_defer/3" do
    test "keeps a tree compiled with bindings apart from the same tree without them" do
      tree = compiled_template("{{ a }}/{{ b }}").parsed_template
      opts = [module_limit: 1_000_000]

      assert {:ok, plain} = Codegen.fetch_or_defer(tree, %{}, opts)
      assert {:ok, specialised} = Codegen.fetch_or_defer(tree, %{"a" => "A"}, opts)

      refute plain == specialised,
             "a tree asked for with bindings was answered with the unbound module"
    end

    test "answers a repeat from the cache rather than compiling again" do
      tree = compiled_template("{{ a }}+{{ b }}").parsed_template
      opts = [module_limit: 1_000_000]

      assert {:ok, first} = Codegen.fetch_or_defer(tree, %{}, opts)
      assert {:ok, ^first} = Codegen.fetch_or_defer(tree, %{}, opts)
    end
  end

  describe ":instrument" do
    defp instrumented(opts) do
      test = self()

      Keyword.merge(opts,
        file_system: {TestFileSystem, nil},
        instrument: fn template, fun ->
          send(test, {:timed, template})
          fun.()
        end
      )
    end

    defp timed_names(acc \\ []) do
      receive do
        {:timed, template} -> timed_names([template | acc])
      after
        0 -> Enum.sort(acc)
      end
    end

    # `known` has to hold something, or the compiler never resolves a literal target; and the
    # callee has to read a runtime var, or its output folds to a literal and nothing renders.
    defp compile_with(source, known, opts) do
      template = compiled_template(source, opts)
      mod = Module.concat([Gas.CodegenCase, "I#{System.unique_integer([:positive])}"])
      {src, _nodes, _covered, _total} = Codegen.source(template.parsed_template, mod, known, opts)
      {:ok, compiled} = Codegen.compile(template.parsed_template, mod, known, opts)
      {compiled, src}
    end

    defp rendered(compiled, vars, opts) do
      {out, _ctx} = compiled.render(%Gas.Context{vars: vars}, opts)
      IO.iodata_to_binary(out)
    end

    test "times a render whose target is only known at runtime" do
      opts = instrumented(codegen: true)
      vars = %{"which" => "greeting", "who" => "Ada"}
      {compiled, src} = compile_with("{% render which, name: who %}", %{"other" => 1}, opts)

      assert src =~ "render_partial(", "this test is not driving the runtime-target path"
      assert rendered(compiled, vars, opts) == "Hi Ada!"
      assert timed_names() == ["greeting"]
    end

    test "times a render the compiler resolved and inlined" do
      opts = instrumented(codegen: true)

      {compiled, src} =
        compile_with("[{% render 'greeting', name: who %}]", %{"other" => 1}, opts)

      assert src =~ "render_module(", "this test is not driving the inlined path"
      assert rendered(compiled, %{"who" => "Ada"}, opts) == "[Hi Ada!]"
      assert timed_names() == ["greeting"]
    end

    # The template and the loop variable are named differently on purpose: with both called
    # "each" this could not tell which of the two the span was named after.
    test "times a `render for` once for the whole loop, under the template's name" do
      opts = instrumented(codegen: true)
      src = "{% render 'counted' for xs as each %}"
      {compiled, generated} = compile_with(src, %{"other" => 1}, opts)

      assert generated =~ "render_each(", "this test is not driving the render-for path"
      assert rendered(compiled, %{"xs" => ["a", "b"]}, opts) == "1/2 2/2 "
      assert timed_names() == ["counted"]
    end

    test "times an interpreted render too, not only a compiled one" do
      opts = instrumented(codegen: false)
      template = compiled_template("{% render 'greeting', name: who %}", opts)

      assert {:ok, out, _errors} =
               Gas.render(template, %Gas.Context{vars: %{"who" => "Ada"}}, opts)

      assert IO.iodata_to_binary(out) == "Hi Ada!"
      assert timed_names() == ["greeting"], "the interpreter renders sections with no timing"
    end

    test "renders identically with no instrument given" do
      plain = [file_system: {TestFileSystem, nil}, codegen: true]
      source = "[{% render 'greeting', name: who %}]"
      vars = %{"who" => "Ada"}

      {with_it, _} = compile_with(source, %{"other" => 1}, instrumented(codegen: true))
      {without, _} = compile_with(source, %{"other" => 1}, plain)

      assert rendered(without, vars, plain) ==
               rendered(with_it, vars, instrumented(codegen: true))
    end
  end
end
