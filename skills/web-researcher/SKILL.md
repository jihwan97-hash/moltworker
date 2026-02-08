---
name: web-researcher
description: Search the web using Serper (Google Search) API and perform autonomous research sessions. Use for finding current information, news, market data, and studying topics. Requires SERPER_API_KEY env var.
---

# Web Researcher

Search the web and perform autonomous research using the Serper (Google Search) API.

## Prerequisites

- `SERPER_API_KEY` environment variable set

## Usage

### Quick Search
```bash
node /root/clawd/skills/web-researcher/scripts/research.js "your search query"
```

Returns structured JSON with search results including titles, URLs, snippets, and extracted page content.

### Autonomous Study Session
```bash
node /root/clawd/skills/web-researcher/scripts/study-session.js
```

Automatically picks the next topic from the configured topic list, researches it, and outputs a formatted study report. Topics rotate round-robin.

### Custom Topic Study
```bash
node /root/clawd/skills/web-researcher/scripts/study-session.js --topic "crypto-market"
```

## Topics Configuration

Edit `/root/clawd/skills/web-researcher/topics.default.json` to customize study topics. Each topic has:
- `name`: Topic identifier
- `queries`: List of search queries to run for this topic

## Output Format

Research results are output as JSON to stdout:
```json
{
  "query": "search query",
  "timestamp": "2026-02-07T12:00:00Z",
  "results": [
    {
      "title": "Article Title",
      "url": "https://example.com/article",
      "snippet": "Brief excerpt from search results",
      "content": "Extracted article text (first 2000 chars)"
    }
  ]
}
```

### Study Material from User
When the user provides text, documents, or files to study:
1. Read the provided material carefully
2. Extract key concepts, facts, and insights
3. Create a structured summary
4. Store the summary in your memory using your brain memory system

For files: read the file, summarize it, and remember the key points.
For text: analyze the text, identify important information, and store it.

Always confirm what you learned and ask if the user wants you to focus on specific aspects.

## When to Use

- User asks about current events or recent news
- Need up-to-date market data or prices
- Researching topics that require fresh information
- Scheduled study sessions for continuous learning
- User provides material to study (text, files, links)
