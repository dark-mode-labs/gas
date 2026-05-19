defmodule Gas.Caching.PersistentTermCacheTest do
  use ExUnit.Case, async: false

  alias Gas.Caching.PersistentTermCache

  setup do
    key = "ptc_test_" <> Integer.to_string(System.unique_integer([:positive]))

    on_exit(fn ->
      :persistent_term.erase({PersistentTermCache, key})
    end)

    {:ok, key: key}
  end

  test "get/1 returns {:error, :not_found} for an unwritten key", %{key: key} do
    assert PersistentTermCache.get(key) == {:error, :not_found}
  end

  test "get/1 returns {:ok, value} after put/2", %{key: key} do
    template = %Gas.Template{parsed_template: [%Gas.Text{loc: nil, text: "hi"}]}
    assert PersistentTermCache.put(key, template) == :ok
    assert PersistentTermCache.get(key) == {:ok, template}
  end

  test "put/2 overwrites an existing value", %{key: key} do
    t1 = %Gas.Template{parsed_template: [%Gas.Text{loc: nil, text: "one"}]}
    t2 = %Gas.Template{parsed_template: [%Gas.Text{loc: nil, text: "two"}]}

    assert PersistentTermCache.put(key, t1) == :ok
    assert PersistentTermCache.put(key, t2) == :ok
    assert PersistentTermCache.get(key) == {:ok, t2}
  end
end
