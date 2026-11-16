import json, sys, urllib.request

REPO = "turanmertkaraca-bit/casper-nirvana-debian"

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "ci-inspect"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

for run in sys.argv[1:]:
    print("===== run %s =====" % run)
    try:
        d = get("https://api.github.com/repos/%s/actions/runs/%s/jobs?per_page=30" % (REPO, run))
    except Exception as e:
        print("  error:", e)
        continue
    if "message" in d:
        print("  API:", d["message"])
        continue
    for j in d.get("jobs", []):
        print("JOB %s: %s/%s" % (j["name"], j["status"], j["conclusion"]))
        for s in j.get("steps", []):
            mark = "FAIL>" if s["conclusion"] == "failure" else "     "
            print("   %s %2d. %s: %s" % (mark, s["number"], s["name"], s["conclusion"]))
