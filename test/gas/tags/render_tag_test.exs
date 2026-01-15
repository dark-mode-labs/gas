defmodule Gas.Tags.RenderTagTest do
  use ExUnit.Case, async: true
  alias Gas.Tags.RenderTag
  alias Gas.{Lexer, ParserContext}
  alias Gas.Parser.Loc

  defmodule TestFileSystem do
    @behaviour Gas.FileSystem

    @impl true
    def read_template_file("second", _opts) do
      {:ok, "hello there"}
    end

    def read_template_file("broken", _opts) do
      {:ok, "{% {{"}
    end

    def read_template_file("vars", _opts) do
      {:ok, "{{ var1[1] }} {{ var2 }}"}
    end

    def read_template_file("with_var", _opts) do
      {:ok, "{{ with_var['key'] }}"}
    end

    def read_template_file("item_file", _opts) do
      {:ok, "{{ item['key'] }}"}
    end

    def read_template_file("dotted_arg", _opts) do
      {:ok, "{{ arg.sub-arg }} {{ arg2 }}"}
    end

    def read_template_file("dotted_arg_2", _opts) do
      {:ok, "{{ arg.arg1 }} {{ arg.sub-arg }} {{ arg2 }} {{ arg.arg2 }}"}
    end

    def read_template_file("dotted_arg_4", _opts) do
      {:ok, "<div {{ arg.id }} {{ arg.second_id }}>{{ arg.content }}</div>"}
    end

    def read_template_file("dotted_arg_3", _opts) do
      {:ok,
       "{% capture rendered %}{% for i in items %}{% assign local_result = result | append: i  %}{% render 'dotted_arg_4', arg: arg, arg.second_id: i, arg.content: local_result %}{% endfor %}{% endcapture %}<div {{ arg.id }}>{{ rendered }}</div>"}
    end

    def read_template_file("forloop", _opts) do
      {:ok,
       "{{forloop.key}}{{ forloop.index }}{{ forloop.rindex }}{{ forloop.first }}{{ forloop.last }}{{ forloop.length }}"}
    end
  end

  defp parse(template) do
    context = %ParserContext{rest: template, line: 1, column: 1, mode: :normal}

    with {:ok, "render", context} <- Lexer.tokenize_tag_start(context) do
      RenderTag.parse("render", %Loc{line: 1, column: 1}, context)
    end
  end

  describe "parse/2" do
    test "simple" do
      template = ~s<{% render "file1" %}>

      assert parse(template) ==
               {:ok,
                %RenderTag{
                  loc: %Loc{line: 1, column: 1},
                  template: %Gas.Literal{value: "file1", loc: nil},
                  arguments: %{}
                }, %ParserContext{rest: "", line: 1, column: 21, mode: :normal}}
    end

    test "arguments" do
      template = ~s<{% render "file1", var1: arg1, var2: 2 %}>

      assert parse(template) ==
               {:ok,
                %RenderTag{
                  loc: %Loc{line: 1, column: 1},
                  template: %Gas.Literal{value: "file1", loc: nil},
                  arguments: %{
                    "var1" => %Gas.Variable{
                      original_name: "arg1",
                      loc: %Loc{column: 26, line: 1},
                      identifier: "arg1",
                      accesses: []
                    },
                    "var2" => %Gas.Literal{
                      loc: %Loc{column: 38, line: 1},
                      value: 2
                    }
                  }
                }, %ParserContext{rest: "", line: 1, column: 42, mode: :normal}}
    end

    test "arguments no initial comma" do
      template = "{% render 'inner_object' key: value, title: 'text' %}"

      assert {:ok,
              %Gas.Tags.RenderTag{
                template: %Gas.Literal{value: "inner_object", loc: nil},
                arguments: %{
                  "key" => %Gas.Variable{identifier: "value"},
                  "title" => %Gas.Literal{value: "text"}
                }
              }, %Gas.ParserContext{rest: "", line: 1, column: 54, mode: :normal, tags: nil}} =
               parse(template)
    end

    test "with arguments" do
      template = ~s<{% render "file1" with products[0] %}>

      assert parse(template) ==
               {:ok,
                %RenderTag{
                  loc: %Loc{line: 1, column: 1},
                  template: %Gas.Literal{value: "file1", loc: nil},
                  arguments:
                    {:with,
                     {%Gas.Variable{
                        original_name: "products[0]",
                        loc: %Loc{column: 24, line: 1},
                        identifier: "products",
                        accesses: [
                          %Gas.AccessLiteral{
                            loc: %Loc{column: 33, line: 1},
                            value: 0
                          }
                        ]
                      }, %Gas.Literal{value: "file1", loc: nil}}}
                }, %ParserContext{rest: "", line: 1, column: 38, mode: :normal}}
    end

    test "with-as arguments" do
      template = ~s<{% render "file1" with products[0] as product %}>

      assert parse(template) ==
               {:ok,
                %RenderTag{
                  loc: %Loc{line: 1, column: 1},
                  template: %Gas.Literal{value: "file1", loc: nil},
                  arguments:
                    {:with,
                     {%Gas.Variable{
                        original_name: "products[0]",
                        loc: %Loc{column: 24, line: 1},
                        identifier: "products",
                        accesses: [
                          %Gas.AccessLiteral{
                            loc: %Loc{column: 33, line: 1},
                            value: 0
                          }
                        ]
                      }, "product"}}
                }, %ParserContext{rest: "", line: 1, column: 49, mode: :normal}}
    end

    test "for arguments" do
      template = ~s<{% render "file1" for products[0] %}>

      assert parse(template) ==
               {
                 :ok,
                 %RenderTag{
                   loc: %Loc{column: 1, line: 1},
                   arguments: {
                     :for,
                     {
                       %Gas.Variable{
                         original_name: "products[0]",
                         accesses: [
                           %Gas.AccessLiteral{
                             loc: %Loc{column: 32, line: 1},
                             value: 0
                           }
                         ],
                         identifier: "products",
                         loc: %Loc{column: 23, line: 1}
                       },
                       %Gas.Literal{value: "file1", loc: nil}
                     }
                   },
                   template: %Gas.Literal{value: "file1", loc: nil}
                 },
                 %ParserContext{
                   column: 37,
                   line: 1,
                   mode: :normal,
                   rest: ""
                 }
               }
    end

    test "for-as arguments" do
      template = ~s<{% render "file1" for products[0] as product %}>

      assert parse(template) ==
               {
                 :ok,
                 %RenderTag{
                   arguments: {
                     :for,
                     {
                       %Gas.Variable{
                         original_name: "products[0]",
                         accesses: [
                           %Gas.AccessLiteral{
                             loc: %Loc{column: 32, line: 1},
                             value: 0
                           }
                         ],
                         identifier: "products",
                         loc: %Loc{column: 23, line: 1}
                       },
                       "product"
                     }
                   },
                   loc: %Loc{column: 1, line: 1},
                   template: %Gas.Literal{value: "file1", loc: nil}
                 },
                 %ParserContext{column: 48, line: 1, mode: :normal, rest: ""}
               }
    end

    test "wrong args" do
      template = ~s<{% render "file1" in files %}>

      assert parse(template) ==
               {:error, "Expected arguments, 'with' or 'for'", %{column: 19, line: 1}}
    end
  end

  describe "Renderable impl" do
    test "renders basic file" do
      template = ~s<{% render "second" %}>
      context = %Gas.Context{}

      {:ok, tag, _rest} = parse(template)
      options = [file_system: {TestFileSystem, nil}]

      assert Gas.Renderable.render(tag, context, options) == {[["hello there"]], context}
    end

    test "renders variables" do
      template = ~s<{% render "vars", var1: array, var2: "value2" %}>
      context = %Gas.Context{vars: %{"array" => [1, 2]}}

      {:ok, tag, _rest} = parse(template)
      options = [file_system: {TestFileSystem, nil}]

      assert Gas.Renderable.render(tag, context, options) == {[["2", " ", "value2"]], context}
    end

    test "renders with" do
      template = ~s<{% render "with_var" with array[1]  %}>
      context = %Gas.Context{vars: %{"array" => [%{"key" => "value1"}, %{"key" => "value2"}]}}

      {:ok, tag, _rest} = parse(template)
      options = [file_system: {TestFileSystem, nil}]

      assert Gas.Renderable.render(tag, context, options) == {[["value2"]], context}
    end

    test "renders with as" do
      template = ~s<{% render "item_file" with array[1] as item  %}>
      context = %Gas.Context{vars: %{"array" => [%{"key" => "value1"}, %{"key" => "value2"}]}}

      {:ok, tag, _rest} = parse(template)
      options = [file_system: {TestFileSystem, nil}]

      assert Gas.Renderable.render(tag, context, options) == {[["value2"]], context}
    end

    test "renders for using a list" do
      template = ~s<{% render "with_var" for array  %}>
      context = %Gas.Context{vars: %{"array" => [%{"key" => "value1"}, %{"key" => "value2"}]}}

      {:ok, tag, _rest} = parse(template)
      options = [file_system: {TestFileSystem, nil}]

      assert Gas.Renderable.render(tag, context, options) ==
               {[["value1"], ["value2"]], context}
    end

    test "renders for using a list as" do
      template = ~s<{% render "item_file" for array as item  %}>
      context = %Gas.Context{vars: %{"array" => [%{"key" => "value1"}, %{"key" => "value2"}]}}

      {:ok, tag, _rest} = parse(template)
      options = [file_system: {TestFileSystem, nil}]

      assert Gas.Renderable.render(tag, context, options) ==
               {[["value1"], ["value2"]], context}
    end

    test "renders for using a single item" do
      template = ~s<{% render "with_var" for array[1] %}>
      context = %Gas.Context{vars: %{"array" => [%{"key" => "value1"}, %{"key" => "value2"}]}}

      {:ok, tag, _rest} = parse(template)
      options = [file_system: {TestFileSystem, nil}]

      assert Gas.Renderable.render(tag, context, options) == {[["value2"]], context}
    end

    test "renders for + forloop" do
      template = ~s<{% render "forloop" for array  %}>
      context = %Gas.Context{vars: %{"array" => [%{"key" => "value1"}, %{"key" => "value2"}]}}

      {:ok, tag, _rest} = parse(template)
      options = [file_system: {TestFileSystem, nil}]

      assert Gas.Renderable.render(tag, context, options) ==
               {[
                  ["value1", "1", "2", "true", "false", "2"],
                  ["value2", "2", "1", "false", "true", "2"]
                ], context}
    end

    test "renders with dotted arg" do
      template = ~s<{% render "dotted_arg", arg.sub-arg: var1, arg2: var2 %}>
      context = %Gas.Context{vars: %{"var1" => "mickey", "var2" => "mouse"}}

      {:ok, tag, _rest} = parse(template)
      options = [file_system: {TestFileSystem, nil}]

      assert Gas.Renderable.render(tag, context, options) ==
               {[["mickey", " ", "mouse"]], context}
    end

    test "interpolation within interpolation" do
      template = ~s<{% render "dotted_arg", arg.sub-arg: var1, arg2: var2 %}>
      context = %Gas.Context{vars: %{"var1" => "mickey", "var2" => "<h1>{{ var1 }} mouse</h1>"}}

      {:ok, tag, _rest} = parse(template)

      options = [file_system: {TestFileSystem, nil}]

      assert Gas.Renderable.render(tag, context, options) ==
               {[["mickey", " ", "<h1>mickey mouse</h1>"]], context}
    end

    test "shit" do
      template =
        "{% assign var = 'hello ' | append: var1 %}{% capture result %}{% render 'dotted_arg_2', arg.sub-arg: var, arg.arg1: var1, arg2: var2 %}{% endcapture %}{% render 'dotted_arg_3', arg.id: 0, result: result, items: items %}"

      context = %Gas.Context{vars: %{"var1" => "mickey", "var2" => "mouse", "items" => [1, 2]}}

      {:ok, template} = Gas.parse(template)
      options = [file_system: {TestFileSystem, nil}]

      assert {:ok, flattened, []} =
               Gas.render(template, context, options)

      assert "<div 0><div 0 1>mickey hello mickey mouse 1</div><div 0 2>mickey hello mickey mouse 2</div></div>" ==
               IO.iodata_to_binary(flattened)
    end
  end
end
