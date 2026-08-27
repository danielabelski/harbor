#!/usr/bin/env bash
# Runtime proof for `harbor up librechat tei`: on a running stack, librechat-rag
# is up with TEI as its openai-compatible embedder, and the LibreChat user path
# that embeds files -- an Agents endpoint agent with the File Search capability,
# uploaded through POST /api/files (endpoint=agents, tool_resource=file_search),
# exactly what the agent builder's "File Search" upload sends -- produces an
# openai_embed request in TEI's log and an `route=embed` ingestion in rag-api.
# Requires librechat + tei up; creates a throwaway LibreChat user and agent and
# removes both (plus the probe file) afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
prefix=$(./harbor.sh config get container.prefix 2>/dev/null || echo harbor)
lc_port=$(./harbor.sh config get librechat.host.port 2>/dev/null || echo 33891)
lc="$prefix.librechat"; rag="$prefix.librechat-rag"; tei="$prefix.tei"; db="$prefix.librechat-db"

docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$rag" \
  | grep -q '^RAG_OPENAI_BASEURL=http://tei:80/v1$' \
  || { echo "librechat-rag embedder is not TEI"; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$rag")" = "true" ] \
  || { echo "librechat-rag is not running"; exit 1; }

stamp=$(date +%s)
email="tei-probe-$stamp@harbor.local"; pass="TeiProbe-$stamp!"
cleanup() {
  docker exec "$db" mongosh --quiet LibreChat --eval "db.users.deleteOne({email:'$email'})" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker exec "$lc" node config/create-user.js "$email" tei-probe "tei-probe-$stamp" "$pass" --email-verified=true >/dev/null

before=$(docker logs "$tei" 2>&1 | grep -c openai_embed || true)
docker exec -i -e EMAIL="$email" -e PASS="$pass" -e PORT="$lc_port" "$lc" node - <<'JS'
const base = `http://localhost:${process.env.PORT}`;
const ua = { "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) Chrome/120 harbor-tei-probe" };
const call = async (path, init = {}) => {
  const res = await fetch(base + path, { ...init, headers: { ...ua, ...(init.headers || {}) } });
  if (!res.ok) throw new Error(`${path} -> ${res.status} ${await res.text()}`);
  return res;
};
(async () => {
  const { token } = await (await call("/api/auth/login", { method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: process.env.EMAIL, password: process.env.PASS }) })).json();
  const auth = { Authorization: `Bearer ${token}` };
  const agent = await (await call("/api/agents", { method: "POST",
    headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify({ name: "harbor-tei-probe", provider: "ollama", model: "probe",
      tools: ["file_search"] }) })).json();
  try {
    const form = new FormData();
    form.append("file", new Blob(["harbor tei probe " + Date.now()], { type: "text/plain" }), "tei-probe.txt");
    form.append("file_id", crypto.randomUUID());
    form.append("endpoint", "agents");
    form.append("tool_resource", "file_search");
    form.append("agent_id", agent.id);
    const file = await (await call("/api/files", { method: "POST", headers: auth, body: form })).json();
    if (!file.embedded) throw new Error("upload was not embedded: " + JSON.stringify(file));
    await call("/api/files", { method: "DELETE", headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ agent_id: agent.id, files: [{ file_id: file.file_id, filepath: file.filepath, embedded: true }] }) })
      .catch(() => {});
  } finally {
    await call(`/api/agents/${agent.id}`, { method: "DELETE", headers: auth }).catch(() => {});
  }
})().catch((e) => { console.error(e.message); process.exit(1); });
JS

for _ in $(seq 1 30); do
  after=$(docker logs "$tei" 2>&1 | grep -c openai_embed || true)
  [ "$after" -gt "$before" ] && { echo "TEI served $((after-before)) openai_embed request(s) for the LibreChat File Search upload"; exit 0; }
  sleep 1
done
echo "no openai_embed request reached TEI"; exit 1
