// Homebox's tabs on the chassis window: Inventory, Users, and Homebox's part of Updates and Storage.
(function (P) {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  function hbUrl(st) { return ((st.app || {}).url || "").replace(/\/$/, ""); }
  function links(st) { document.querySelectorAll(".hb-link").forEach(function (x) { x.href = hbUrl(st) ? hbUrl(st) + (x.dataset.path || "") : "#"; }); }
  function touched(id) { ["input", "change"].forEach(function (e) { $(id).addEventListener(e, function () { $(id).dataset.touched = "1"; }); }); }
  function quiet(id, v) { if (!$(id).dataset.touched) $(id).value = v == null ? "" : v; }
  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
  function money(v, cur) {
    var code = (cur || "usd").toUpperCase();
    try { return new Intl.NumberFormat(undefined, { style: "currency", currency: code, maximumFractionDigits: v >= 1000 ? 0 : 2 }).format(v || 0); }
    catch (e) { return (Math.round((v || 0) * 100) / 100) + " " + code; }
  }
  function day(iso) { var d = new Date(iso + "T00:00:00"); return isNaN(d) ? iso : d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" }); }
  function inDays(n) { return n === 0 ? "today" : n === 1 ? "tomorrow" : "in " + n + " days"; }
  function worth(cols) {   // one figure per currency
    var by = {}; cols.forEach(function (c) { var k = (c.currency || "usd").toLowerCase(); by[k] = (by[k] || 0) + (c.value || 0); });
    var keys = Object.keys(by); return keys.length ? keys.map(function (k) { return money(by[k], k); }).join(" + ") : money(0, "usd");
  }

  // ---------------------------------------------------------------- Inventory
  touched("wa-days");
  P.register("inventory", {
    render: function (st) {
      var a = st.app || {}, cols = a.collections || [], end = a.ending || [], t = $("in-tiles");
      links(st);
      var items = cols.reduce(function (s, c) { return s + (c.items || 0); }, 0), locs = cols.reduce(function (s, c) { return s + (c.locations || 0); }, 0);
      var warr = cols.reduce(function (s, c) { return s + (c.warranty || 0); }, 0);
      P.clear(t); P.tile(t, String(items), items === 1 ? "item" : "items"); P.tile(t, worth(cols), "worth, as bought"); P.tile(t, String(locs), locs === 1 ? "location" : "locations");
      P.tile(t, String(warr), "under warranty"); P.tile(t, String(end.length), "warranties ending within " + (a.within || 30) + " days");
      quiet("wa-days", String(a.warn_days == null ? 30 : a.warn_days));
      $("in-window").textContent = "the next " + (a.within || 30) + " days" + (a.ended ? " · " + plural(a.ended, "ended", "ended") + " in the last 30" : "");
      var sig = JSON.stringify([cols, end, a.url]), tb = $("in-cols"); if (tb.dataset.sig === sig) return; tb.dataset.sig = sig; P.clear(tb);
      if (!cols.length) { var r0 = P.el("tr"), c0 = P.cell("Nothing in Homebox yet.", "empty"); c0.colSpan = 7; r0.appendChild(c0); tb.appendChild(r0); }
      cols.forEach(function (c) {
        P.row(tb, [c.name, P.cell(String(c.items || 0), "n"), P.cell(String(c.locations || 0), "n"), P.cell(money(c.value, c.currency), "n"),
          P.cell(String(c.warranty || 0), "n"), P.cell(String(c.files || 0), "n"), P.cell(String(c.people || 0), "n")]);
      });
      var te = $("in-ending"); P.clear(te);
      if (!end.length) { var r1 = P.el("tr"), c1 = P.cell("No warranty ends in the next " + (a.within || 30) + " days.", "empty"); c1.colSpan = 4; r1.appendChild(c1); te.appendChild(r1); }
      end.forEach(function (i) {
        var what = P.el("div"); what.appendChild(P.el("b", i.name)); if (cols.length > 1) what.appendChild(P.el("span", i.collection, "sub"));
        var when = P.el("div"); when.appendChild(P.el("span", day(i.ends))); when.appendChild(P.el("span", inDays(i.days), "sub" + (i.days <= 7 ? " soon" : "")));
        var open = P.el("a", "Open", "btn"); open.href = hbUrl(st) ? hbUrl(st) + "/item/" + i.id : "#"; open.target = "_blank"; open.rel = "noopener";
        P.row(te, [P.cell(what), i.location || "–", P.cell(when), P.cell(open, "n")]);
      });
    },
    badge: function (st) { var n = (((st.app || {}).ending) || []).filter(function (i) { return i.days <= 7; }).length; $("badge-inventory").hidden = !n; $("badge-inventory").textContent = String(n); }
  });
  $("wa-save").onclick = function () { P.act("warranty", { days: $("wa-days").value }).then(function () { $("wa-days").dataset.touched = ""; }); };
  // The overview's own tiles: how much is in Homebox, and for how many people.
  P.register("overview", { tiles: function (t, st) { var cols = (st.app || {}).collections || [], n = cols.reduce(function (s, c) { return s + (c.items || 0); }, 0);
    P.tile(t, String(n), n === 1 ? "item in Homebox" : "items in Homebox"); P.tile(t, String(((st.app || {}).users || []).length), "people"); } });

  // ---------------------------------------------------------------- Users
  P.register("users", {
    render: function (st) {
      var a = st.app || {}, us = a.users || [], t = $("us-tiles"), cols = a.collections || [];
      links(st); $("us-pending").hidden = !a.first_account_pending;
      P.clear(t); P.tile(t, String(us.length), us.length === 1 ? "person" : "people"); P.tile(t, String(cols.length), cols.length === 1 ? "collection" : "collections");
      P.tile(t, a.signups ? "open" : "closed", "sign-ups");
      var s = $("su-state"), b = $("su-btn"); P.clear(s); P.clear(b);
      s.appendChild(a.signups ? P.chip("open — anyone who can reach Homebox", "warn") : P.chip("closed — by invitation", "ok"));
      b.appendChild(P.btn(a.signups ? "Close sign-ups" : "Open sign-ups", "", function () { P.act("signups", { on: a.signups ? 0 : 1 }, a.signups ? null : "Let anyone who can reach Homebox make an account? Homebox restarts for a moment."); }));
      var tb = $("us-list"), sig = JSON.stringify(us) + "|" + P.busy + "|" + P.role; if (tb.dataset.sig === sig) return; tb.dataset.sig = sig; P.clear(tb);
      if (!us.length) { var r0 = P.el("tr"), c0 = P.cell("No accounts yet.", "empty"); c0.colSpan = 5; r0.appendChild(c0); tb.appendChild(r0); }
      us.forEach(function (u) {
        var who = P.el("div"); who.appendChild(P.el("b", u.name)); who.appendChild(P.el("span", u.email, "sub"));
        var cs = P.el("div"); (u.collections || []).forEach(function (c) { var l = P.el("div", c.name); if (c.role === "owner") l.appendChild(P.el("span", " · owner", "muted")); cs.appendChild(l); });
        if (!(u.collections || []).length) cs.textContent = "none";
        var act = u.password ? P.btn("New password", "", function () { P.act("userpw", { id: u.id }, "Make a new password for " + u.name + " (" + u.email + ")?\n\nThe old one stops working, and they're signed out on every device."); })
                             : P.el("span", u.oidc ? "single sign-on" : "no password", "muted small");
        P.row(tb, [P.cell(who), P.cell(cs), u.sessions ? plural(u.sessions, "device", "devices") : "–", u.created ? P.ago(u.created) : "–", P.cell(act, "n")]);
      });
    }
  });
  P.register("secretNote", function () { return "Use it to sign in to Homebox with that email address, then keep it in a password manager — or change it in Homebox (Profile)."; });

  // ---------------------------------------------------------------- Updates: Homebox is pinned to a release
  P.register("updates", {
    render: function (st) {
      var box = $("upd-app"), iu = st.image_update || {}, a = st.app || {}; P.clear(box);
      box.appendChild(P.el("p", "Installed: Homebox " + (st.version || "?") + (a.image ? " (" + a.image + ")" : "") + "."));
      if (iu.available) {
        box.appendChild(P.el("p", "Homebox " + iu.latest + " is out. Updating backs everything up first, then moves Homebox to the new release; it's away for a minute or two.", "muted small"));
        var l = P.el("a", "What's new"); l.href = iu.page; l.target = "_blank"; l.rel = "noopener"; box.appendChild(l); box.appendChild(P.el("span", " "));
        box.appendChild(P.btn("Update Homebox to " + iu.latest, "primary", function () { P.act("hbupdate", {}, "Update Homebox to " + iu.latest + "? A backup is made first; Homebox is away for a minute or two."); }));
      } else if (iu.error) box.appendChild(P.el("p", "Couldn't look for a newer Homebox: " + iu.error + ".", "muted small"));
      else box.appendChild(P.el("p", (iu.note ? iu.note + ". " : iu.latest ? "This is the newest Homebox release (" + iu.latest + ")" + (iu.checked ? ", checked " + P.ago(iu.checked) : "") + ". " : "")
        + "The package keeps Homebox at a release and moves it on when you say so.", "muted small"));
    }
  });

  // ---------------------------------------------------------------- Storage
  P.register("storage", { render: function (app, st, box) {
    P.clear(box); var c = P.el("div", null, "card"); c.appendChild(P.el("h2", "Inside the data volume")); var tbl = P.el("table"), tb = P.el("tbody"); tbl.appendChild(tb); c.appendChild(tbl);
    [["Database (SQLite)", app.database], ["Photos, receipts and manuals", app.files]].forEach(function (p) { P.kv(tb, p[0], P.mb(p[1] || 0), true); });
    box.appendChild(c);
  } });
})(window.Panel);
