defmodule TeslaMateWeb.Plugs.SecurityHeadersTest do
  use TeslaMateWeb.ConnCase

  @tag auth: false
  test "issues a fresh nonce for each page and uses it on application scripts", %{conn: conn} do
    first = get(conn, "/sign_in")
    second = get(conn, "/sign_in")

    nonce = first.assigns.csp_nonce
    assert byte_size(Base.decode64!(nonce)) == 24
    refute nonce == second.assigns.csp_nonce

    [policy] = get_resp_header(first, "content-security-policy")
    assert policy =~ "'nonce-#{nonce}'"
    [script_policy] = Regex.run(~r/script-src [^;]+/, policy)
    refute script_policy =~ "'unsafe-inline'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "frame-src 'none'"
    assert get_resp_header(first, "x-content-type-options") == ["nosniff"]

    scripts =
      first.resp_body
      |> Floki.parse_document!()
      |> Floki.find("script[src]")

    assert length(scripts) == 2

    for script <- scripts do
      assert Floki.attribute([script], "nonce") == [nonce]
      assert Floki.attribute([script], "data-cfasync") == ["false"]
    end
  end

  @tag auth: false
  test "does not accept a nonce supplied by the request", %{conn: conn} do
    response = conn |> put_req_header("x-csp-nonce", "untrusted-nonce") |> get("/sign_in")
    refute response.assigns.csp_nonce == "untrusted-nonce"
    [policy] = get_resp_header(response, "content-security-policy")
    refute policy =~ "untrusted-nonce"
  end
end
