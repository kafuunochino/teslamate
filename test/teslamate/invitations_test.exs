defmodule TeslaMate.InvitationsTest do
  use TeslaMate.DataCase, async: false
  alias TeslaMate.{Accounts, AccountFixtures, Repo}
  alias TeslaMate.Accounts.{Invitation, Invitations}

  setup do
    admin = AccountFixtures.system_admin()
    {:ok, _} = Accounts.set_registration_policy(admin, true, true)
    %{admin: admin}
  end

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{
        email: "invited-#{System.unique_integer([:positive])}@example.com",
        name: "Invited User",
        password: "correct horse battery staple 42",
        password_confirmation: "correct horse battery staple 42"
      },
      extra
    )
  end

  test "missing, malformed and unknown codes cannot create accounts" do
    for code <- [nil, "", " ", "not-a-code", %{}, String.duplicate("X", 1000)] do
      params = attrs(%{invitation_code: code})
      assert {:error, :invalid_invitation} = Accounts.register_public_user(params)
      refute Accounts.get_user_by_email(params.email)
    end
  end

  test "one successful member registration consumes a code, without granting cars", %{
    admin: admin
  } do
    assert {:ok, [code]} = Invitations.generate(admin, 1)

    assert {:ok, user} =
             Accounts.register_public_user(
               attrs(%{
                 invitation_code: " #{String.downcase(code)} ",
                 role: :admin,
                 is_system_admin: true
               })
             )

    assert user.role == :member
    refute user.is_system_admin
    assert Accounts.list_accessible_cars(user) == []

    assert {:error, :invalid_invitation} =
             Accounts.register_public_user(attrs(%{invitation_code: code}))

    assert %{used: 1, available: 0} = Invitations.list(admin)
  end

  test "failed validation or duplicate email does not consume the invitation", %{admin: admin} do
    {:ok, [code]} = Invitations.generate(admin, 1)

    assert {:error, %Ecto.Changeset{}} =
             Accounts.register_public_user(attrs(%{invitation_code: code, password: "short"}))

    assert Invitations.valid?(code)

    assert {:error, %Ecto.Changeset{}} =
             Accounts.register_public_user(attrs(%{invitation_code: code, email: admin.email}))

    assert Invitations.valid?(code)
    assert %{used: 0, available: 1} = Invitations.list(admin)
  end

  test "competing submissions never reuse a successfully consumed invitation", %{admin: admin} do
    {:ok, [code]} = Invitations.generate(admin, 1)

    tasks =
      for _ <- 1..2,
          do: Task.async(fn -> Accounts.register_public_user(attrs(%{invitation_code: code})) end)

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :invalid_invitation}, &1)) == 1
    assert Repo.aggregate(from(i in Invitation, where: not is_nil(i.used_at)), :count) == 1
  end

  test "global closure overrides valid invites; unrestricted signup leaves them untouched", %{
    admin: admin
  } do
    {:ok, [code]} = Invitations.generate(admin, 1)
    {:ok, _} = Accounts.set_registration_policy(admin, false, true)

    assert {:error, :registration_closed} =
             Accounts.register_public_user(attrs(%{invitation_code: code}))

    {:ok, _} = Accounts.set_registration_policy(admin, true, false)
    assert {:ok, _} = Accounts.register_public_user(attrs())
    assert Invitations.valid?(code)
  end

  test "management rechecks privilege and never returns stored hashes or raw codes", %{
    admin: admin
  } do
    member = AccountFixtures.member()
    assert {:error, :forbidden} = Invitations.generate(member, 2)

    assert {:error, :forbidden} =
             Invitations.list(%{member | role: :admin, is_system_admin: true})

    assert {:error, :forbidden} = Accounts.set_registration_policy(member, true, false)
    assert {:ok, codes} = Invitations.generate(admin, 3)
    assert length(Enum.uniq(codes)) == 3
    page = Invitations.list(admin)
    assert %{total: 3, available: 3} = page
    refute inspect(page) =~ hd(codes)
    refute Map.has_key?(hd(page.entries), :code_hash)
    for row <- Repo.all(Invitation), do: assert(byte_size(row.code_hash) == 32)
    assert {:error, :forbidden} = Invitations.revoke(member, hd(page.entries).id)
  end

  test "revocation rejects unused codes while retaining used status and supports bounded batches",
       %{admin: admin} do
    for quantity <- [0, -1, 101, "5", nil],
        do: assert({:error, _} = Invitations.generate(admin, quantity))

    {:ok, [code]} = Invitations.generate(admin, 1)
    [row] = Invitations.list(admin).entries
    assert {:ok, :ok} = Invitations.revoke(admin, row.id)
    refute Invitations.valid?(code)

    assert {:error, :invalid_invitation} =
             Accounts.register_public_user(attrs(%{invitation_code: code}))

    assert %{revoked: 1, available: 0} = Invitations.list(admin)
    {:ok, _} = Invitations.generate(admin, 21)
    assert %{entries: entries, pages: 2} = Invitations.list(admin)
    assert length(entries) == 20
    assert length(Invitations.list(admin, 2).entries) == 2
  end
end
