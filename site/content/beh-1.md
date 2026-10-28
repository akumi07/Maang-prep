## Answering framework | P4 | must

### How behavioral rounds are evaluated

#### Core idea
Behavioral rounds ("Tell me about a time…") assess **how you work**: ownership, judgement, collaboration, handling conflict and failure, bias for action, and growth. At product companies they carry real weight: a strong technical candidate is often rejected here, or **down-levelled** (SDE-1 instead of SDE-2) for answers that sound junior. Amazon runs **Leadership Principles** questions in every round; Google evaluates "Googleyness and leadership"; Meta has a dedicated behavioural round; Indian product companies run hiring-manager rounds focused on ownership.

#### How it works
**STAR(R) structure**
| Part | Share of answer | What to say |
|---|---|---|
| **S**ituation | ~10% | context in 1–2 sentences: team, system, stakes |
| **T**ask | ~10% | your specific responsibility or the problem |
| **A**ction | ~60% | what **you** did (use "I", not "we"): decisions, trade-offs, how you handled people |
| **R**esult | ~15% | measurable outcome (latency −40%, incident resolved in 20 min, adopted by 3 teams) |
| **R**eflection | ~5% | what you learned or would do differently |

**What interviewers listen for (SDE-2 signals)**
- **Scope**: beyond your ticket: influencing design, unblocking others, cross-team work.
- **Ownership**: you followed things through to production and after; you fixed problems you didn't cause.
- **Data**: decisions backed by metrics; results quantified.
- **Judgement**: trade-offs you weighed, and what you chose *not* to do.
- **Self-awareness**: honest mistakes, concrete learning, no blaming.
- **Conflict handled with respect**: disagree with data, then commit.

**Amazon Leadership Principles to map your stories to**: Customer Obsession, Ownership, Invent and Simplify, Are Right A Lot, Learn and Be Curious, Hire and Develop the Best, Insist on the Highest Standards, Think Big, Bias for Action, Frugality, Earn Trust, Dive Deep, Have Backbone; Disagree and Commit, Deliver Results, Strive to be Earth's Best Employer, Success and Scale Bring Broad Responsibility.

**Build a story bank**: 8–10 stories, each tagged with 2–4 principles, so one story can answer several questions. Keep each to about 2–3 minutes spoken.

| Story (from your work) | Can answer |
|---|---|
| Search latency −40% with CompletableFuture (Tata 1mg) | Dive Deep, Deliver Results, Invent and Simplify, "proudest technical achievement" |
| Redis soft-TTL caching (+35% hit ratio, −30% DB load) | Invent and Simplify, Customer Obsession, Frugality |
| PostgreSQL query tuning (−50% query time) | Dive Deep, Insist on Highest Standards |
| Downstream integration debugging under tight timelines (Allianz) | Bias for Action, Ownership, "production issue" |
| OAuth 2.0 SSO work (Allianz) | Learn and Be Curious, Earn Trust (security), cross-team collaboration |
| Socket.io real-time updates (−80% latency, OnTheMove) | Customer Obsession, Bias for Action |
| NeuronixAI side project | Learn and Be Curious, Think Big, Ownership |
| A disagreement about a design or approach | Have Backbone; Disagree and Commit |
| A mistake or failure | Earn Trust, Learn and Be Curious |

#### Real-world example
Two answers to "Tell me about a time you improved performance": *Junior*: "We had slow APIs so we added caching and it got faster." *SDE-2*: "Medicine search p95 was about X ms and conversion dropped on slow searches. I profiled with traces and found 3 sequential downstream calls. I parallelised them with CompletableFuture on a dedicated, sized pool, added timeouts with fallbacks so a slow offers service couldn't block search, and propagated trace context into the pool threads. p95 dropped 40% over a week of production traffic, and I documented the pattern so two other endpoints adopted it." The second has measurement, trade-offs, scope and results.

#### Interview questions
?? Why do product companies put so much weight on behavioral rounds?
Senior engineers spend much of their time on ambiguity, collaboration, prioritisation and ownership, not just coding. Past behaviour is the best available predictor of future behaviour, and level is decided largely by the scope and judgement shown in these stories.

#### Tricky questions
?? What if you don't have a story for a specific question?
Pause, say "Let me think of the best example", and adapt the closest story from your bank, framed for that question. If you truly have none, describe a smaller-scale example honestly, or how you'd handle it, but real stories score far better, which is why the bank needs breadth.

#### Interview simulation
Practise out loud with a timer: each story in 2–3 minutes, with "I" statements and at least one number. Record yourself. Expect follow-ups like "What would you do differently?", "What was the hardest part?", "How did you measure that?", "What did your manager think?", so know the details behind every claim.

### Presenting your projects (resume deep dive)

#### Core idea
Every product-company loop includes a **resume deep dive**: "Walk me through your most impactful project." Interviewers probe until they find the edge of your knowledge. Every bullet on your resume must survive **3 levels of "why" and "how did you measure it?"**

#### How it works
**The 5-part project pitch (3–4 minutes)**
1. **Context**: what the product or system does, who uses it, the scale (QPS, users, data).
2. **Architecture**: the main components, and where your part sits (draw it!).
3. **Your contribution**: the specific problems you owned and the decisions you made.
4. **Hard parts and trade-offs**: what was difficult, the alternatives considered, why you chose what you did.
5. **Results and learning**: metrics, and what you'd do differently now.

**Prepare these for each resume bullet**
| Bullet | Questions to expect |
|---|---|
| Search latency −40% (CompletableFuture) | Baseline numbers? How measured (p50/p95, tool)? Thread pool size and why? What if a downstream hangs? Why not reactive or virtual threads? Exceptions in futures? MDC/trace propagation? |
| Redis soft TTL, +35% hit ratio, −30% DB load | What's soft vs hard TTL? How do you prevent stampedes (a lock? single-flight)? Staleness tolerance? Key design? Eviction policy? What happens if Redis is down? |
| PostgreSQL tuning, query time −50% | Which queries? What did EXPLAIN show? Which indexes, and their write cost? Any schema change? How did you deploy indexes safely (CONCURRENTLY)? |
| Kafka for event-driven communication | Topics and keys? Ordering? Delivery semantics? Idempotent consumers? Retries and DLQ? Lag monitoring? Why Kafka instead of REST or RabbitMQ? |
| Versioned REST APIs, validation, exception handling | Versioning strategy? Error format? How were breaking changes handled? |
| OAuth 2.0 SSO (Allianz) | Which flow? Which IdP? How was the token validated? Key rotation? What exactly did you build vs the platform team? |
| Downstream integration debugging | A specific incident: symptoms, hypothesis, tools, root cause, fix, prevention. |
| OnTheMove: 50K+ daily requests, 99.8% uptime | How was uptime measured? Rate limiting design? Pagination type? MongoDB index changes (+45%)? Socket.io scaling? |
| NeuronixAI | Architecture end to end; chunking; embeddings; pgvector index; routing reliability; evaluation; costs; what you'd change. |

**Honesty rules**
- Separate **"I"** from **"we"**; claim only what you did. Interviewers detect inflation through follow-up depth.
- If a number is an estimate, say so ("roughly, from our Grafana dashboards").
- "I don't know, but here's how I'd find out" is far better than bluffing.

#### Real-world example
A sample opening for your strongest project (fill in your real numbers): "At Tata 1mg I worked on the medicine search service, which handles [N] requests per second at peak. Search called pricing, inventory and offers services sequentially, and p95 was around [X] ms. I owned the latency work: I traced the request, found that most of the time was waiting on independent I/O, and parallelised the calls with CompletableFuture on a dedicated pool sized from the measured latencies, with per-call timeouts and fallbacks. Separately, I introduced a soft-TTL Redis cache with single-flight refresh. Together, p95 dropped about 40%, the cache hit ratio rose 35%, and DB load fell 30%. If I did it again on Java 21, I'd evaluate virtual threads with structured concurrency to simplify the code."

#### Interview questions
?? What was the most technically challenging thing you worked on?
Pick the story with the deepest trade-offs and that you understand end to end (likely the search latency work or NeuronixAI). Explain the problem, the constraints, the alternatives, your decision, and the measurable outcome. Expect deep follow-ups, so choose a story where you can go three levels deep.

?? What would you do differently in that project?
Show growth: better measurement upfront (a baseline dashboard), load testing before release, a simpler design or better observability, writing a design doc for review, or a modern approach you've learned since (virtual threads, an outbox for Kafka publishing, CDC-based cache invalidation).

#### Tricky questions
?? The interviewer says "40% seems low for parallelising calls. Why not more?"
Explain the real constraints: the latency became max(calls) instead of the sum, but one call dominated (the slowest service), plus serialisation and DB time remained. Further gains needed caching or optimising that slow service. Showing you understand *why* the number is what it is is the point.

#### Interview simulation
Practise the deep dive with a friend acting as a sceptical interviewer who asks "why?" and "how do you know?" after every sentence. Draw the architecture on paper in under 2 minutes. You should be able to discuss each technology choice's alternatives.

## STAR stories | P4 | must

### Conflict with a teammate or senior

#### Core idea
"Tell me about a time you disagreed with a colleague / your manager / a senior engineer." They're assessing whether you can **disagree constructively with data**, listen, find common ground, escalate appropriately, and **commit** once a decision is made, without damaging the relationship.

#### How it works
**Structure for conflict stories**
1. The disagreement: about *what* (a technical approach, priority, process), not about personalities.
2. **Understand their perspective first**: what constraints or goals they had.
3. **Use data or experiments**: a benchmark, a prototype, a prod metric, a design doc with options and trade-offs.
4. **Resolution**: agreement, a compromise, or you disagreed and committed (and supported the decision fully).
5. **Outcome and relationship**: the result, plus that you kept working well together.

**Do**: stay respectful, focus on the customer or system outcome, show you could be wrong. **Don't**: make the other person look stupid, "I was right and they were wrong" endings, conflicts about trivial things, or stories where your manager had to save you.

#### Real-world example
**Skeleton** (replace with your real situation): "On the search service, a senior engineer proposed adding a Redis cache with a 1-hour TTL to fix latency. I was concerned that stale prices or availability could show out-of-stock medicines, which hurts customers. I asked about the constraints they were optimising for, then proposed splitting it: cache the slowly changing parts (descriptions, salts) with long TTLs and keep price and stock fresher, using a soft TTL with background refresh. I built a quick prototype and showed hit-ratio and staleness numbers from a day of traffic replay. We agreed on the split design. It shipped with a 35% hit-ratio increase without stale-stock complaints, and the senior engineer later suggested the soft-TTL pattern for another service."

#### Interview questions
?? Tell me about a time you disagreed with your manager.
Choose a professional disagreement (scope, an approach, a timeline), show that you raised it with data in the right forum, that you understood their reasoning, and how it resolved: either you persuaded them with evidence, or you committed fully to their decision and helped it succeed (and what you learned).

?? What do you do if you still disagree after the discussion?
Make sure my concern and data are clearly heard and documented, and propose a reversible experiment or checkpoint if possible. Once the decision is made, commit fully and help it succeed; if new data appears, raise it again constructively. Escalate only for serious issues (security, customer harm, ethics).

#### Tricky questions
?? What if the conflict was with someone you just didn't get along with?
Focus on what you did to improve the working relationship: a 1:1 conversation about working styles, clarifying responsibilities, assuming good intent. Show maturity; avoid criticising them.

#### Interview simulation
Keep it to about 2.5 minutes. The interviewer will likely follow up with "What would you have done if they hadn't agreed?" Have the disagree-and-commit answer ready.

### A failure or mistake

#### Core idea
"Tell me about a time you failed / made a mistake." They're assessing **ownership, honesty and learning**. The worst answers are fake failures ("I work too hard") or blaming others. The best: a real mistake with real impact, owned plainly, fixed quickly, and turned into a lasting improvement (often a process or automation that prevents recurrence).

#### How it works
1. **The mistake**: own it in one sentence ("I deployed a change without checking X").
2. **Impact**: be honest about the consequences (users affected, time).
3. **Immediate response**: how you detected, communicated and mitigated it (rollback, a fix).
4. **Root cause**: why it happened (a process gap, an assumption).
5. **Prevention**: what you changed (a test, an alert, a checklist, a CI step) so it can't recur, ideally helping others too.
6. **Learning**: how you work differently now.

#### Real-world example
**Skeleton**: "I added an index to speed up a query, but created it without CONCURRENTLY on a large table during business hours. It locked writes for a few minutes and orders failed. I noticed the error-rate alert, cancelled the operation, and told my lead and the on-call channel immediately. Afterwards, I wrote a migration checklist (CONCURRENTLY for indexes, lock_timeout, off-peak timing, a staging run on production-sized data) and added a CI check that flags non-concurrent index creation in migrations. Since then, no migration-related incidents on our service." (Use a real mistake of yours; interviewers can tell.)

#### Interview questions
?? What's the biggest mistake you've made at work?
Choose a real, moderately significant mistake (not catastrophic negligence, not trivial). Own it, explain the impact and how you fixed it, and focus on the prevention you put in place and how it changed your habits.

?? Tell me about a project that didn't go as planned.
Similar structure, but it can be about estimation, scope or requirements misunderstandings: what you'd do differently (earlier prototypes, clarifying requirements, raising risks sooner).

#### Tricky questions
?? Should you choose a mistake that was partly someone else's fault?
Focus on **your** part. You can mention context briefly, but the answer must centre on what you could have done differently. Blame-shifting is a red flag.

#### Interview simulation
Deliver it calmly and matter-of-factly. Confidence in owning a mistake signals seniority. Expect "How did your team react?" and "What would you do if it happened again?"

### Ownership beyond your scope

#### Core idea
"Tell me about a time you took on something outside your responsibilities / went above and beyond." **Ownership** is the most important signal for SDE-2: noticing problems nobody owned and fixing them, thinking long-term, acting on behalf of the whole system and the customer, not just your ticket.

#### How it works
Good ownership stories involve:
- Spotting a problem others ignored (a flaky test suite, missing monitoring, a recurring manual task, a performance issue, a poor developer experience).
- Taking initiative **with alignment** (telling your lead, not going rogue).
- Delivering a fix that helped others (the team, other teams, customers).
- Following through to adoption and results.

#### Real-world example
**Skeleton**: "Our team had repeated late-night escalations because downstream integration failures were hard to trace: logs from different services couldn't be correlated. It wasn't on our roadmap, but I proposed adding trace ids to every request and propagating them through our HTTP clients and Kafka headers. I built it as a small shared library over two weeks alongside my sprint work, with my lead's agreement, and documented it. The time to find the root cause of integration issues dropped from hours to minutes, and two neighbouring teams adopted the library."

#### Interview questions
?? Tell me about a time you did something that wasn't your job.
An initiative that improved the team or the customer outcome, done with alignment and followed through, with measurable impact. Show that you balanced it with your committed work.

?? Describe something you built that others now use.
A tool, library, document, runbook or dashboard, and how you drove adoption (demos, docs, support).

#### Tricky questions
?? Isn't doing work outside your scope risky if your own deliverables slip?
Yes, which is why the story should show prioritisation: you made sure your commitments were met (or renegotiated transparently), timeboxed the initiative, and got buy-in. Ownership isn't heroics.

#### Interview simulation
Expect follow-ups: "How did you convince others to use it?", "What would have happened if you hadn't done it?", "How did you find the time?" Prepare concrete answers.

### Tight deadline and prioritisation

#### Core idea
"Tell me about a time you had to deliver under a tight deadline / with competing priorities." They're assessing **prioritisation, trade-offs, communication and quality judgement**: what you cut, what you protected, and how you kept stakeholders informed.

#### How it works
1. The deadline and why it mattered (a business event, a client commitment).
2. **Scoping**: you split must-haves from nice-to-haves and negotiated scope.
3. **Risk management**: what could go wrong, and the mitigations (feature flags, extra testing on critical paths).
4. **Communication**: proactive updates to stakeholders and early warning of risks.
5. **Result**: delivered (or partially, with a clear plan), with the quality bar protected where it mattered.
6. **Follow-up**: paying back any shortcuts (tech debt tickets you actually did).

#### Real-world example
**Skeleton (Allianz)**: "A partner integration had to go live for a customer journey release in one week, and the downstream API was behaving inconsistently. I listed the scenarios by business impact, built the critical happy path plus the two most common error cases first, and wrapped the integration with timeouts and a graceful error message so failures wouldn't break the journey. I flagged the remaining edge cases to my lead on day 2 with a proposal to handle them after launch behind monitoring. We launched on time; the monitoring caught one edge case in week one, which I fixed within a day."

#### Interview questions
?? How do you prioritise when everything is urgent?
Clarify impact and deadlines with stakeholders; rank by customer and business impact versus effort; protect critical quality aspects (security, data integrity); communicate the trade-offs explicitly; get agreement on what's deferred; revisit as new information arrives.

?? Tell me about a time you missed a deadline.
Own it; explain what caused it (an estimation miss, a dependency); how and when you communicated; how you minimised the impact; and what you changed (earlier risk flags, buffer estimates, incremental delivery).

#### Tricky questions
?? Did you ever cut corners to meet a deadline? Was that OK?
Show judgement: acceptable shortcuts (less polish, manual steps, deferred non-critical features, tracked tech debt) vs unacceptable ones (skipping security, data integrity or testing of critical paths). Show you paid the debt back.

#### Interview simulation
Emphasise **communication**: interviewers want to hear that stakeholders were never surprised. Include one specific trade-off and why you chose it.

### Production incident story

#### Core idea
"Tell me about a production issue you handled." This story shows **calm under pressure, debugging method, mitigation-first thinking, communication and prevention**. Your resume's "resolved downstream integration issues through log analysis and root-cause investigation under tight timelines" is the anchor.

#### How it works
1. **Detection**: how it surfaced (an alert, a client complaint) and the impact (users, revenue, SLA).
2. **Triage and mitigation**: what you did first to reduce the impact (rollback, a feature flag, a retry or circuit breaker, failover, a manual workaround).
3. **Investigation**: your hypotheses and evidence (logs correlated by request id, metrics, traces, thread dumps, a DB analysis).
4. **Root cause**: technical and contributing factors.
5. **Fix and verification**.
6. **Prevention**: alerts, tests, runbooks, design changes; a postmortem.
7. **Communication**: updates to stakeholders throughout.

#### Real-world example
**Skeleton**: "Customers on a journey dashboard intermittently saw errors; about 5% of requests failed. I first checked whether it correlated with our deploy (it didn't), then filtered logs by failing request ids and saw timeouts calling a downstream policy service, but only from some pods. The pattern pointed to stale pooled connections: the downstream had moved behind a new load balancer, and idle connections were silently dropped after its idle timeout, so the first request on each stale connection hung until our 30s read timeout. Mitigation: we reduced the connection max idle time and added a retry for idempotent GETs. Root fix: an idle-eviction setting below the LB's timeout, a 3s timeout with a circuit breaker, and an alert on downstream error rate. Errors went to zero and we added it to the integration runbook." (Replace with your real incident's details.)

#### Interview questions
?? Walk me through how you debug a production issue.
Assess the impact and scope, mitigate first (rollback, a flag), then investigate systematically: what changed, metrics to localise, traces for the slow or failed component, logs for details, form and test hypotheses. Fix, verify, then prevent with alerts, tests and runbooks, and write a blameless postmortem.

#### Tricky questions
?? What if you couldn't find the root cause?
Say so honestly; describe the mitigations and the added observability (more logging, tracing) to catch it next time, and the hypotheses you ruled out. Sometimes the right answer is "we made the system resilient to that failure class while we kept investigating."

#### Interview simulation
Use precise technical vocabulary (connection pools, timeouts, idempotent retries, circuit breakers). This story doubles as a technical depth check, and interviewers will dig into the mechanics.

### Disagree and commit

#### Core idea
Amazon's "Have Backbone; Disagree and Commit": you should challenge decisions you disagree with, respectfully and with data, even when it's uncomfortable; but once a decision is made, you commit fully. Interviewers want evidence of **both** halves: the courage to speak up, and the maturity to commit.

#### How it works
1. The decision you disagreed with, and **why** (with data or risk analysis).
2. How you raised it (in the right forum, early, constructively, with alternatives).
3. The outcome: the decision went the other way (that makes it the better "commit" story) or yours was adopted.
4. **How you committed**: you executed well, maybe added safeguards, and didn't say "I told you so".
5. The result and what you learned (sometimes that the other view was right).

#### Real-world example
**Skeleton**: "The team decided to use synchronous REST calls between the order and notification services for a launch. I argued for Kafka events, so a notification outage couldn't block orders. Given the deadline, the lead chose REST. I committed: I implemented it with a short timeout, a circuit breaker and async dispatch so failures wouldn't block order placement, and added a metric for notification failures. After launch, the metrics showed occasional failures, which made the case for the event-driven version in the next quarter, which I then led."

#### Interview questions
?? Tell me about a time you went along with a decision you disagreed with.
That's the "commit" half: show that you voiced the concern constructively, accepted the decision, executed it well with mitigations, and evaluated it honestly afterwards.

?? Tell me about a time you pushed back on a senior person.
That's the "backbone" half: a risk you saw (quality, customer impact, security), the data you brought, how you raised it respectfully, and the outcome.

#### Tricky questions
?? When would you not commit?
When a decision is unethical, illegal, or creates serious safety or security risks. Then escalate through the proper channels. For normal technical or product trade-offs, you commit.

#### Interview simulation
Keep the tone positive about the other party. Interviewers listen for respect and for whether you made the chosen path succeed.

### Mentoring and helping others

#### Core idea
"Tell me about a time you helped a teammate / mentored someone / improved your team." At SDE-2 level, impact includes making **others** more effective: onboarding new joiners, reviewing code thoughtfully, sharing knowledge, unblocking people.

#### How it works
Good examples: onboarding a new joiner (a guide, pairing), a knowledge-sharing session (a tech talk on Kafka or caching), detailed code reviews that taught patterns, documentation or runbooks that reduced questions, helping a struggling teammate debug something hard.

Structure: the person's challenge → what you did (specific, patient, teaching rather than doing it for them) → their growth or the team outcome → what you learned about mentoring.

#### Real-world example
**Skeleton**: "A new teammate joined the search service and was struggling with our async code and Kafka consumers. I paired with them for an hour a day during their first week, walked through one request end to end, and wrote a short onboarding doc with diagrams of our flows. I also reviewed their first PRs with explanations rather than just fixes. Within three weeks they shipped a consumer feature independently, and the doc became the standard onboarding material for the team."

#### Interview questions
?? How do you give feedback in code reviews?
Specific, kind and actionable; explain the *why* (a link to a principle or a doc); distinguish blocking issues from suggestions (nit); ask questions instead of commanding ("What do you think about…?"); praise good work; and for bigger design issues, talk synchronously instead of leaving long comment threads.

#### Tricky questions
?? With 2 years' experience, have you really mentored anyone?
Yes, mentoring isn't only formal: onboarding interns or new joiners, knowledge sessions, documentation, helping peers debug. Give a concrete, modest, real example; inflated claims backfire.

#### Interview simulation
Keep it concrete and outcome-oriented: who, what they struggled with, what you did, and the measurable improvement.

### "Why switch?" and "Why this company?"

#### Core idea
Every hiring-manager round asks "Why are you looking to change?" and "Why us?" They're checking motivation, fit, and red flags (badmouthing, only money, job-hopping). Coming from a services company (TCS) to a product company is a very common and well-understood move. Frame it as **growth toward ownership and product impact**, not escape.

#### How it works
**"Why switch?" formula**: appreciate what you learned, name what you want next, and explain why the new role offers it.
> "At TCS I've worked on client projects for Tata 1mg and Allianz, where I got strong hands-on experience with Spring Boot microservices, Kafka, Redis, performance tuning and OAuth-based SSO. What I want next is deeper, long-term ownership of a product: owning services end to end, working with product teams on the customer impact, and solving scale problems over years rather than across client engagements. That's why I'm focusing on product companies like yours."

**Avoid**: complaining about TCS, managers or pay; "I want more money" as the main reason (it can be part of the negotiation later); vague answers.

**"Why this company?"**: research specifics: the product, the engineering blog, the scale challenges, the tech stack, recent launches. Connect them to your experience and interests:
> "Your engineering blog on [specific topic, e.g. their Kafka-based order pipeline / search relevance work] is exactly the kind of problem I've worked on at smaller scale at 1mg. I'm also interested in [their AI initiatives], which connects with my NeuronixAI project."

**Also prepare**: "Where do you see yourself in 3–5 years?" (growing into a senior or tech-lead role with deeper system ownership), "What are you looking for in your next role?", and "Why did you build NeuronixAI?" (curiosity and learning by building, which shows initiative).

#### Real-world example
For a Cursor Forward Deployed Engineer application (customer-facing engineering), the "why" should emphasise working directly with customers on technical problems, AI-assisted development (your daily use of Cursor and Claude), and your backend and integration experience. That's a different emphasis than for a core backend SDE-2 role at Flipkart. Tailor it per company.

#### Interview questions
?? Why do you want to leave TCS after only ~1.5 years there?
Positive and forward-looking: "I've learned a lot quickly across two client projects. I now want long-term ownership of a product and its scale problems, which fits a product company better. I'm being selective rather than moving for the sake of it." Keep it under 45 seconds.

?? What do you know about our company?
Show real research: the product and business model, the scale and the engineering challenges, recent news, and the tech stack from their blog or job description. Connect at least one point to your experience.

#### Tricky questions
?? "Are you interviewing elsewhere?"
It's fine to say yes, briefly and honestly ("I'm in process with a couple of product companies"), and reaffirm your interest in this one. It can also help negotiation timelines.

#### Interview simulation
Write both answers out, trim them to about 45–60 seconds each, and rehearse until they sound natural rather than memorised. Customise the "why us" section for every company.

### Questions to ask the interviewer

#### Core idea
"Do you have any questions for me?" isn't a formality: thoughtful questions show genuine interest, seniority and judgement, and help **you** evaluate the team. Always have 2–3 ready per interviewer type. Never say "No, I'm good."

#### How it works
**To engineers (technical rounds)**
- "What does a typical week look like for an engineer on this team: how much is new features vs operations?"
- "What's the biggest technical challenge the team is facing this year?"
- "How do you handle on-call and production incidents? What does a postmortem look like here?"
- "How are design decisions made: design docs, reviews, RFCs?"
- "What does the deployment pipeline look like? How often do you ship to production?"
- "What's something you'd change about the codebase or architecture if you had time?"

**To hiring managers**
- "What would success look like for this role in the first 6 months?"
- "What are the team's priorities for the next year, and how does this role contribute?"
- "How do engineers grow here: what distinguishes SDE-2s who get promoted to senior?"
- "How does the team work with product and design? Who decides what to build?"
- "What's the biggest challenge for someone joining this team?"

**To senior leaders / bar raisers**
- "What's the engineering culture's biggest strength, and what are you trying to improve?"
- "How is the company investing in AI tooling for engineers?" (fits your AI background)

**Avoid**: questions answered on their careers page; salary or leave questions in technical rounds (save them for HR); negative framing ("Is there a lot of overtime?" works better as "How does the team handle crunch periods?").

#### Real-world example
After a system design round, asking "How does your team handle the dual-write problem between your order DB and Kafka today: outbox, CDC, or something else?" shows that you were engaged and know the space, and the answer tells you about their engineering maturity. Tailor questions to what was discussed.

#### Interview questions
?? What's a good question to ask at the end of an Amazon interview?
Something tied to a Leadership Principle or the team's work: "Can you share an example of how 'Ownership' shows up on this team, maybe a time an engineer drove something beyond their scope?" or "What does the team's operational load look like, and how do you balance it with new features?"

#### Tricky questions
?? The interview went badly. Should you still ask questions?
Yes. Stay engaged and professional; a good closing can leave a better impression, and one weak round doesn't always mean a rejection. Use the time to learn about the team.

#### Interview simulation
Keep a running list in your notes for each company and interviewer type. Pick based on the conversation, and listen to the answers (a follow-up question shows real interest).

## Job search | P4

### Resume, LinkedIn and GitHub

#### Core idea
Your resume gets roughly **6–10 seconds** of human attention after passing ATS keyword filters. It must show **impact with numbers**, the **right keywords** for the role, and a **clean layout**. LinkedIn and GitHub back it up when recruiters search or check you.

#### How it works
**Resume rules (SDE-2 backend)**
- One page (two at most for 5+ years).
- Each bullet: **action verb + what + how (tech) + measurable result**: "Cut medicine search API latency by 40% by parallelising downstream calls with CompletableFuture on a dedicated thread pool."
- Lead with your strongest, most relevant bullets; recent experience first.
- A skills section grouped (languages, frameworks, data, cloud, AI); no rating bars; only what you can defend in an interview.
- Projects: 1–2 strong ones (NeuronixAI) with architecture keywords and a GitHub link.
- Achievements: LeetCode rating and percentile (you have this: top 15%).
- Tailor it per role: for AI-heavy roles move NeuronixAI up; for core backend lead with 1mg performance work.
- ATS-friendly: simple formatting, standard section titles, PDF, keywords from the job description (Java, Spring Boot, microservices, Kafka, distributed systems, AWS).

**LinkedIn**: a headline like "Backend Engineer | Java, Spring Boot, Kafka, Redis | Distributed Systems & GenAI (RAG)"; an About section with 3–4 lines of impact; experience bullets mirroring the resume; "Open to work" visible to recruiters only; recruiters search by keywords and location (Bengaluru).

**GitHub**: pin 2–3 repositories with a strong README (architecture diagram, how to run, design decisions, what you'd improve), clean commits, tests, and Docker compose for running locally. NeuronixAI should look production-minded.

#### Real-world example
Your resume already has quantified bullets (−40% latency, +35% hit ratio, −30% DB load, −50% query time). Improvements to consider: add scale context (requests per second, data size) where you know it; make sure every number is defensible with a measurement story; and keep the most impressive bullet first in each role.

#### Interview questions
?? How do you write a strong resume bullet?
Start with an action verb, state the problem or what you built, name the key technologies or approach, and end with a measurable result and scale. One line or two at most. Avoid duties ("responsible for…").

#### Tricky questions
?? Should you list technologies you've only used in tutorials?
No. Anything on the resume is fair game for deep questions. List what you've used in real work or substantial projects, and separate "familiar" items if needed.

#### Interview simulation
Before each interview, re-read your resume and for each bullet rehearse: the context, your exact contribution, the how, the measurement, and one trade-off. Interviewers often start from a random bullet.

### Referrals and an application strategy

#### Core idea
**Referrals** dramatically increase your chance of getting an interview at product companies compared with cold applications. Combine them with a **tiered target list** and parallel pipelines so offers arrive around the same time (better negotiation).

#### How it works
**Target list (example tiers; adapt to your interests)**
- **Tier 1** (stretch): Google, Amazon, Microsoft, Meta-scale and top product companies (Atlassian, Uber, Salesforce, Adobe, LinkedIn, Databricks…).
- **Tier 2** (strong fits): well-known Indian product companies and unicorns (Flipkart, PhonePe, Razorpay, Swiggy, Zomato, CRED, Meesho, Zepto, Groww…).
- **Tier 3** (practice plus good options): funded startups and mid-size product companies where you can interview early to warm up.
- Plus AI-focused companies matching your GenAI experience (like your Cursor FDE application).

**Referral approach**
- Find alumni (KNIT), ex-colleagues, LinkedIn 2nd-degree connections, and people from communities.
- A short, specific message: "Hi [name], I'm a backend engineer (Java/Spring, Kafka, Redis) with 2 years at TCS on Tata 1mg and Allianz. I'm applying for [role + link/job id] on your team. Here's my resume. Would you be comfortable referring me? Happy to answer any questions." Attach the resume and job id; make it easy for them.
- Follow up once politely after about a week.

**Pipeline management**
- A tracker (a spreadsheet, or your study site's notes): company, role, referral, applied date, stage, next step, notes.
- **Sequencing**: interview with tier 3 first (practice), then tier 2, then tier 1, so that offers converge within 2–3 weeks.
- Keep preparing while interviewing; review every interview right after (the questions asked, what went wrong).
- **Notice period**: TCS notice periods are typically long (often 90 days). Know yours, and whether early release or buyout is possible, since product companies may prefer shorter joining times.

#### Real-world example
A common successful pattern: 25–40 referral requests yield 10–15 interview calls; 3–4 full loops in a 4–6 week window; 1–3 offers, used for negotiation. Start applying around week 10 of the prep plan, as suggested in the 16-week schedule.

#### Interview questions
?? How many companies should you apply to?
Enough to have several active loops at once (3–5) without over-stretching preparation, typically 15–30 targeted applications with referrals over a few weeks, prioritised by fit and interest.

#### Tricky questions
?? Should you apply to your dream company first?
Usually not. Interview performance improves with practice, so do a few lower-priority interviews first. But don't wait so long that timelines can't align; dream companies often have longer processes.

#### Interview simulation
Before each loop, ask the recruiter about the format (number of rounds, types, which language, whether the code comprehension or AI-assisted round is included) and prepare specifically. Recruiters are allies, so ask them.

### Salary research and negotiation

#### Core idea
Negotiation is expected at product companies. Research market ranges, understand the **compensation components**, avoid revealing your expected number too early, and negotiate with **data and competing offers**, respectfully. (This is general information, not financial advice; your decisions depend on your situation.)

#### How it works
**Components of an offer in India (typical for product companies)**
| Component | Notes |
|---|---|
| Base (fixed) salary | the most important for stability; the basis for future hikes |
| Variable / performance bonus | target % of base; ask how much actually pays out historically |
| Joining bonus | one-time; may have a clawback if you leave within a year |
| RSUs / ESOPs | RSUs (listed companies) vest over a schedule (e.g. 4 years, possibly front- or back-loaded); ESOPs (startups) are options with uncertain value: ask the strike price, vesting, exit history |
| Relocation, benefits | insurance, learning budget, etc. |

"CTC" in India often combines all of these; compare **fixed pay** and **year-1 cash** separately from equity.

**Research**: levels.fyi, AmbitionBox, Glassdoor, Blind, and peers at those companies (for SDE-2 in Bengaluru, ranges vary widely by company tier).

**Process**
1. Early "expected CTC?" question: deflect politely if possible ("I'm focusing on finding the right role; I'm sure we can agree on a fair number if there's a fit. Could you share the budgeted range?"). If you must answer, give a well-researched range anchored high but realistic.
2. Current CTC: many Indian companies ask for it and may verify it. Answer honestly, and steer towards the market value of the role rather than a percentage hike.
3. After the offer: thank them, ask for the full breakdown in writing, take time (2–5 days is normal).
4. Counter with data: competing offers, market ranges, your interview performance and level fit. Negotiate the components flexibly (base, joining bonus, RSUs).
5. Be respectful and decisive; don't use offers you wouldn't accept as leverage dishonestly.

#### Real-world example
Typical negotiation outcomes when a candidate has a competing offer: an increase in base or RSUs, a joining bonus to cover a notice-period buyout or a lost bonus, or occasionally a level reconsideration. Without competing offers, improvements are usually smaller but still possible.

#### Interview questions
?? How do you answer "What's your expected salary?" in an early HR call?
Prefer to learn their budgeted range first. If pressed, give a researched range based on market data for the role and level (not on your current salary), and say you're flexible depending on the total compensation and the role.

#### Tricky questions
?? Should you accept a verbal offer immediately?
No. Express enthusiasm, ask for the written offer with the full breakdown, review the joining date and notice-period implications, compare with your other options, then negotiate or accept within the agreed time.

#### Interview simulation
Role-play the negotiation call with a friend: open with appreciation, state your request with a reason ("Based on my competing offer of X and the market data for SDE-2, I'd like to discuss a base of Y"), stay quiet after asking, and be ready with priorities (which component matters most to you).

### Mock interview plan

#### Core idea
Mock interviews convert knowledge into **performance under pressure**: talking while coding, managing time, handling hints, and staying calm. The plan in your checklist: **4 DSA, 3 LLD, 3 HLD, 2 behavioural, 1–2 code comprehension**, spread over weeks 13–16.

#### How it works
**Where to get mocks**: peers preparing for the same companies (swap mocks), friends at product companies, online platforms (Pramp and interviewing.io style platforms, paid mentors), and AI-assisted mock practice for behavioural and system-design question drills (useful, but not a replacement for human interviewers).

**How to run one**
- Use the real format: 45–60 min, a shared editor or whiteboard tool, camera on.
- The interviewer uses a question you haven't seen, and gives hints only when you're stuck.
- Feedback with a rubric: problem solving, coding quality, communication, testing, time management (DSA); requirements, design, trade-offs, depth (HLD); structure, clarity, ownership signals (behavioural).
- Record and review: count filler words, silent stretches, and where time went.

**Schedule (example)**
| Week | Mocks |
|---|---|
| 13 | 1 DSA, 1 LLD, 1 behavioural |
| 14 | 1 DSA, 1 HLD, 1 code comprehension |
| 15 | 1 DSA, 1 LLD, 1 HLD, 1 behavioural |
| 16 | 1 DSA, 1 LLD, 1 HLD (company-specific formats) |

**After each mock**: write down the 3 biggest improvements needed, add mistakes to your notes on the relevant lesson in this site (use "Revise later"), and redo the problem a few days later.

#### Real-world example
Candidates who do 8–12 realistic mocks usually see their biggest gains in communication and time management, not knowledge: they stop going silent while coding, they clarify requirements before designing, and they finish with time to test.

#### Interview questions
?? What should you do when stuck in an interview?
Say what you're thinking ("I'm considering X but worried about Y"), try a simpler version or a brute force first, work through a small example, and ask a clarifying question. Interviewers often give hints when they see structured thinking; silence gives them nothing.

#### Tricky questions
?? Is it bad to take a hint?
No, it's normal. What matters is how you use it: quickly incorporate it and progress. Needing many hints for basics is a negative; taking one hint on a hard step is fine.

#### Interview simulation
Treat the mocks as real: same preparation, same timing, same seriousness. Track your mock scores on the home page using "Revise later" for weak areas, and repeat the weakest category until it's consistent.
