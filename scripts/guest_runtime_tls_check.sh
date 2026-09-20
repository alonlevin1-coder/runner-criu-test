#!/usr/bin/env bash
set -euo pipefail
BUNDLE="${T9_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
LEAF="${T9_CA_CERT:-/usr/local/share/ca-certificates/t9-proxy-ca.crt}"
[ -f "${LEAF}" ] || LEAF="/etc/ssl/certs/t9-proxy-ca.pem"
if [ ! -f "${BUNDLE}" ] || [ ! -f "${LEAF}" ]; then
  echo "FAIL: missing CA files bundle=${BUNDLE} leaf=${LEAF}"
  exit 1
fi
export SSL_CERT_FILE="${BUNDLE}"
export CURL_CA_BUNDLE="${BUNDLE}"
export REQUESTS_CA_BUNDLE="${BUNDLE}"
export AWS_CA_BUNDLE="${BUNDLE}"
export GIT_SSL_CAINFO="${BUNDLE}"
export NODE_EXTRA_CA_CERTS="${LEAF}"
export PIP_CERT="${BUNDLE}"
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "SSL_CERT_FILE=${BUNDLE}"
    echo "CURL_CA_BUNDLE=${BUNDLE}"
    echo "REQUESTS_CA_BUNDLE=${BUNDLE}"
    echo "AWS_CA_BUNDLE=${BUNDLE}"
    echo "GIT_SSL_CAINFO=${BUNDLE}"
    echo "NODE_EXTRA_CA_CERTS=${LEAF}"
    echo "PIP_CERT=${BUNDLE}"
  } >> "${GITHUB_ENV}"
fi
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "CONFIRMED: $*"; }
S3_BUCKET="${T9_S3_BUCKET:-noaa-goes16}"
S3_REGION="${T9_S3_REGION:-us-east-1}"
echo "=== Runtime HTTPS + public S3 (MITM) ==="
python3 -c 'import urllib.request; urllib.request.urlopen("https://example.com/", timeout=30).read(64); print("urllib ok")' || fail "python urllib"
ok "python urllib HTTPS"
VENV=/tmp/t9-tls-venv
if [ ! -x "${VENV}/bin/python" ]; then
  python3 -m venv "${VENV}" || fail "python venv"
  "${VENV}/bin/pip" install -q requests boto3 || fail "pip install requests boto3"
fi
"${VENV}/bin/python" -c 'import requests; r=requests.get("https://example.com/", timeout=30); r.raise_for_status(); print("requests", r.status_code)' || fail "python requests"
ok "python requests HTTPS"
if command -v node >/dev/null 2>&1; then
  node -e 'require("https").get("https://example.com/", (res)=>{if(res.statusCode!==200)process.exit(2);res.resume();res.on("end",()=>console.log("node",res.statusCode));}).on("error",(e)=>{console.error(e);process.exit(1);});' || fail "node https"
  ok "node https"
fi
if command -v ruby >/dev/null 2>&1; then
  ruby -ropen-uri -e 'URI.open("https://example.com/") { |f| f.read(8) }; puts "ruby ok"' || fail "ruby HTTPS"
  ok "ruby HTTPS"
fi
if command -v php >/dev/null 2>&1; then
  php -r 'if (file_get_contents("https://example.com/")===false) { exit(1); } echo "php ok\n";' || fail "php HTTPS"
  ok "php HTTPS"
fi
if command -v go >/dev/null 2>&1; then
  GOTLS="$(mktemp /tmp/t9-go-tls.XXXXXX.go)"
  cat > "${GOTLS}" <<'GO'
package main
import ("fmt"; "io"; "net/http"; "os")
func main() {
  r, err := http.Get("https://example.com/")
  if err != nil { fmt.Fprintln(os.Stderr, err); os.Exit(1) }
  defer r.Body.Close()
  io.Copy(io.Discard, r.Body)
  if r.StatusCode != 200 { os.Exit(2) }
  fmt.Println("go", r.StatusCode)
}
GO
  GOPROXY=off GO111MODULE=off go run "${GOTLS}" || fail "go net/http"
  ok "go net/http HTTPS"
fi
AWS_BIN="$(command -v aws || true)"
if [ -z "${AWS_BIN}" ]; then
  "${VENV}/bin/pip" install -q awscli || fail "pip install awscli"
  AWS_BIN="${VENV}/bin/aws"
fi
"${AWS_BIN}" s3api list-objects-v2 --bucket "${S3_BUCKET}" --max-keys 1 --region "${S3_REGION}" --no-sign-request --output json | "${VENV}/bin/python" -c 'import json,sys; d=json.load(sys.stdin); n=int(d.get("KeyCount") or len(d.get("Contents") or [])); assert n>=1, d; print("aws KeyCount", n)' || fail "aws cli s3"
ok "aws cli S3 ListObjects s3://${S3_BUCKET}"
export S3_BUCKET S3_REGION
"${VENV}/bin/python" -c '
import os, boto3
from botocore import UNSIGNED
from botocore.client import Config
c = boto3.client("s3", region_name=os.environ["S3_REGION"], config=Config(signature_version=UNSIGNED))
r = c.list_objects_v2(Bucket=os.environ["S3_BUCKET"], MaxKeys=1)
print("boto3", r.get("KeyCount"), [o.get("Key") for o in r.get("Contents") or []])
assert (r.get("KeyCount") or 0) >= 1 or r.get("Contents")
' || fail "boto3 S3"
ok "boto3 S3 ListObjects s3://${S3_BUCKET}"
if command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  SDKDIR="$(mktemp -d /tmp/t9-aws-sdk.XXXXXX)"
  export T9_S3_BUCKET="${S3_BUCKET}" T9_S3_REGION="${S3_REGION}"
  (
    cd "${SDKDIR}"
    npm init -y >/dev/null 2>&1
    npm install --no-fund --no-audit --silent @aws-sdk/client-s3@3
    node -e '
const { S3Client, ListObjectsV2Command } = require("@aws-sdk/client-s3");
const client = new S3Client({
  region: process.env.T9_S3_REGION,
  credentials: { accessKeyId: "anonymous", secretAccessKey: "anonymous" },
  signer: { sign: async (request) => request },
});
(async () => {
  const out = await client.send(new ListObjectsV2Command({ Bucket: process.env.T9_S3_BUCKET, MaxKeys: 1 }));
  const n = out.KeyCount || (out.Contents || []).length;
  if (!n) throw new Error("empty list");
  console.log("aws-sdk-js", n);
})().catch((e) => { console.error(e); process.exit(1); });
'
  ) || fail "node AWS SDK S3"
  ok "node @aws-sdk/client-s3 ListObjects s3://${S3_BUCKET}"
fi
ok "runtime HTTPS + public S3 through MITM"
