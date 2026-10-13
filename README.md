# Blog

Notes, experiments and posts on data engineering topics.

```
blog/
├── ideas.md                 post backlog and open questions, all topics
├── STYLE.md                 how posts sound: voice, evidence, structure
├── posts/                   one folder per post: YYYY-MM-DD-topic-slug/
│   └── <post>/              post.md + the scripts and logs behind it
└── topics/                  research per topic, reused across posts
    └── <topic>/
        ├── findings.md      dated log of verified findings, with repro and source
        ├── guides/          reference material
        └── lab/             how to set up a test environment
```

Topics so far: `clickhouse`.

## Workflow

1. Run an experiment in the topic's lab and record the result in `topics/<topic>/findings.md` (version, output, source).
2. When a few findings fit one story, start `posts/YYYY-MM-DD-topic-slug/post.md`.
3. Keep every command from a post in a runnable script next to it, and run it on a fresh environment before publishing.

## New topic

```bash
mkdir -p topics/<topic>/{guides,lab}
cp topics/clickhouse/findings.md topics/<topic>/findings.md   # then keep only the template at the bottom
```

## Website

`site/` turns `posts/*/post.md` into a static site in `site/_site/`.

```bash
cd site
npm install                 # once
node build.mjs --drafts     # build, including posts with `draft: true`
npm run dev                 # build with drafts + serve at http://localhost:8000
node build.mjs              # production build (drafts left out)
```

Post front matter:

```yaml
---
title: "..."
date: YYYY-MM-DD
description: "One sentence, used for search results and link previews."
tags: [clickhouse]
tested_on: ClickHouse 26.9      # optional
series: Inside ClickHouse       # optional: posts with the same series get a parts box and a "Next" link
part: 1                         # required with series
draft: true                     # remove to publish
---
```

Files next to `post.md` with extensions `.sql .sh .py .png .jpg .svg .gif .webp` are published with the post, so link them relatively, e.g. `[script](follow-one-row.sql)`.

The build fails if a published post links to a post that isn't built (for example, Part 1 linking to a Part 2 that is still a draft). Publish a series part together with every part it links to.
