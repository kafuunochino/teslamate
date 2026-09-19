# Render only hard-coded fixtures; --no-start keeps Repo and vehicle services off.
{:ok, _} = Application.ensure_all_started(:tzdata)
[directory] = System.argv()
File.mkdir_p!(Path.join(directory, "preview"))

for page <- ["home", "trips", "trip", "charging"] do
  File.write!(
    Path.join([directory, "preview", page <> ".html"]),
    TeslaMateWeb.PortalPreview.document(page)
  )
end

html =
  Phoenix.View.render_to_string(TeslaMateWeb.PortalView, "index.html",
    registration_policy: %{allow_registration: true, require_invitation: true}
  )

File.write!(Path.join(directory, "portal.html"), html)
