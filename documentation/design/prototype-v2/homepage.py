"""Prototype for #254: the homepage of main rearranged in the product-first order."""
import re

ROOT = "/home/ubuntu/act-runs/design/v2"
p = f"{ROOT}/index.html"
h = open(p).read()
GH = "https://github.com/taspinar/agentic-coding-template"


def section(sid):
    a = h.index(f'<section id="{sid}"')
    b = h.index('</section>', a) + len('</section>')
    return a, b


def cut(sid):
    global h
    a, b = section(sid)
    s = h[a:b]
    h = h[:a] + h[b:]
    return s


# Hero: positioning and one line of facts (DESIGN.md: one line, no tiles).
h = h.replace(
    '<p class="lede">An open-source, risk-aware workflow for AI coding agents. From requirements to verified pull requests, with independent reviews, traceable evidence and human control.</p>',
    '<p class="lede">The engineering workflow around your coding agents, from requirements to reviewed pull request. Claude Code and Codex do the work; the workflow adds the review, the evidence and the limits, and the merge stays yours.</p>', 1)
h = h.replace('<a href="/workflow/">How the workflow runs</a></div></div></div>',
              '<a href="/workflow/">How the workflow runs</a></div></div></div>'
              '<p class="facts-line"><span>Reviewed by another provider</span><span>Effort follows risk</span><span>Evidence for every acceptance criterion</span><span>No script merges</span></p>', 1)

# Problem.
h = h.replace('<h2 id="why-h">Writing the code is the fast part</h2>',
              '<h2 id="why-h">Generation is no longer the bottleneck</h2>', 1)

# Risk.
h = h.replace('<h2 id="risk-h">Effort follows risk</h2>', '<h2 id="risk-h">More risk, more evidence</h2>', 1)

trace = cut("trace")
runs = cut("runs")
learn = cut("learn")
start = cut("start")

review = f'''<section id="review" aria-labelledby="review-h"><div class="wrap sec"><header><h2 id="review-h">The agent that writes the code does not judge it</h2><p>Enforced by <a href="{GH}/blob/main/scripts/review-feature.sh"><code>review-feature.sh</code></a>.</p></header><div class="body">
<p>The reviewer is always an agent of another provider than the implementer: the script reads which provider implemented the feature from its run records and refuses a reviewer of the same one. The reviewer can only read.</p>
<div class="handoff"><div><h3>Implementer</h3><ul><li>Reads the Issue, your comments, the requirements and the architecture</li><li>Asks before it builds when a decision is unclear</li><li>Writes the code and the tests</li><li>Runs the checks and records evidence for each criterion</li></ul></div>
<p class="handoff-mid" aria-hidden="true"><span>the content it checked</span></p>
<div><h3>Reviewer</h3><ul><li>Reads the same Issue, the requirements and the diff</li><li>Reviews exactly the content the checks passed for</li><li>Reports findings by severity and the impact on the architecture</li><li>Cannot change a file</li></ul></div></div>
</div></div></section>'''

control = f'''<section id="control" aria-labelledby="control-h"><div class="wrap sec"><header><h2 id="control-h">Automation stops where ownership begins</h2><p>Every gate on the <a href="/workflow/">workflow page</a>.</p></header><div class="body">
<p>You are not asked everywhere. You decide at fixed points, and the run stops for you when it cannot go on safely.</p>
<ol class="gates">
<li class="you"><b>Approve the requirements</b><span>Project Grill drafts them from your description; nothing is planned before you approve.</span></li>
<li class="you"><b>Approve the plan</b><span>Architecture and roadmap, after a review by another provider; you merge the planning pull request.</span></li>
<li class="ask"><b>Answer when asked</b><span>An implementer that finds a decision unclear stops with its questions instead of guessing.</span></li>
<li class="you"><b>Decide on the findings</b><span>Step by step you approve the triage; unattended, the triage is recorded for you to read.</span></li>
<li class="you"><b>Merge</b><span>Every pull request; a protected change or a review that sees major impact on the architecture asks for your approval by name.</span></li>
</ol>
</div></div></section>'''

trail = f'''<ol class="trail" aria-label="The records of feature 217">
<li><b>Finding</b><span>The analysis of 41 runs: a fixed finding came back as unresolved in five runs.</span></li>
<li><b>Issue</b><a href="{GH}/issues/217">#217</a><span>Six acceptance criteria.</span></li>
<li><b>Completion record</b><span>The implementer's claim, criterion by criterion, with evidence.</span></li>
<li><b>Review findings</b><a href="{GH}/issues/217">on #217</a><span>Five rounds, each review and triage published.</span></li>
<li><b>Verification</b><span>Recorded for exactly the content that was reviewed.</span></li>
<li><b>Pull request</b><a href="{GH}/pull/222">#222</a><span>Merged by the owner.</span></li>
</ol>'''
trace = trace.replace('<h2 id="trace-h">Every claim has a record</h2>', '<h2 id="trace-h">Every claim has a record</h2>', 1)
trace = re.sub(r'(<div class="body">)', r'\1<p>One feature, from the finding that started it to the merged pull request. Each step left a record that anyone can open.</p>' + trail.replace('\\', '\\\\'), trace, count=1)

cta = f'''<section id="cta" aria-labelledby="cta-h"><div class="wrap cta"><h2 id="cta-h">Build with agents. Ship with evidence.</h2><div class="actions"><a class="btn" href="/docs/">Get started</a><a href="{GH}">Source on GitHub</a></div><p>Open source, MIT licence. Runs on your machine with Claude Code and Codex.</p></div></section>'''

# Order: hero, problem, plan once, risk, review, control, records, runs, learn, start, call to action.
a, b = section("risk")
h = h[:b] + review + control + trace + runs + learn + start + cta + h[b:]
h = h.replace('</head>', '<link rel="stylesheet" href="/proto-home.css"></head>', 1)
open(p, "w").write(h)
print("ok")
