 ## Overview
 
Sub-O-TX is a strict-mode Bash utility that fetches passive DNS and URL data for domains using the AlienVault OTX API, producing clean, deduplicated outputs ideal for recon pipelines and SOC workflows.

---

##  Features
-  **DNS mode:** Fetches a domain’s passive DNS records once, outputs unique hostnames.  
-  **URL mode:** Retrieves paginated URL indicators (`-l` to set page size).  
-  **Multi-API key rotation:** Use multiple OTX keys from a file for seamless rotation.  
-  **Smart rate limiting:** Handles `429` responses with cooldowns and retry ceilings.  
-  **Strict-mode safe:** Uses `set -euo pipefail` and full dependency checks.  
-  **Automatic logging:** Results stored in per-domain folders under `logs_otx/`.

---

##  Requirements
- Bash 4+  
- `curl`, `jq`, `sed`, `sort`, `mktemp`, `date` (all must be in your `$PATH`)  
- AlienVault OTX API key(s)

---

##  Installation
```bash
git clone https://github.com/0xAshura/sub-o-tx.git
cd sub-o-tx
chmod +x otx.sh
````

---

##  Usage

```bash
./otx.sh -d <domain> -k <api_key|file> -t <dns|url> [-l <limit>]
```

### Examples

**Fetch passive DNS for a single domain**

```bash
./otx.sh -d example.com -k YOUR_KEY -t dns
```

**Fetch paginated URLs (100 per page)**

```bash
./otx.sh -d example.com -k YOUR_KEY -t url -l 100
```

**Use multiple API keys from file**

```bash
./otx.sh -d example.com -k otx_tokens.txt -t url -l 50
```

**Batch mode for multiple domains**

```bash
./otx.sh -f domains.txt -k otx_tokens.txt -t dns
```

---

##  Options

| Flag               | Description                                      |
| ------------------ | ------------------------------------------------ |
| `-d <domain>`      | Process a single domain                          |
| `-f <file>`        | File containing multiple domains (one per line)  |
| `-k <key or file>` | Literal API key or file with multiple keys       |
| `-t <dns or url>`  | Choose between passive DNS or paginated URL mode |
| `-l <limit>`       | Page size for URL mode (default: 100)            |

---

##  Output

Results are saved under:

```
logs_otx/<domain>/dns_data.txt   # for DNS mode
logs_otx/<domain>/url_data.txt   # for URL mode
```

Each file contains **unique, clean entries** — ready for recon or automation workflows.

---

##  Rate Limiting & Environment Variables

Sub-O-TX uses built-in backoff strategies and per-key spacing.
You can fine-tune cooldown behavior via environment variables:

| Variable          | Default | Description                                     |
| ----------------- | ------- | ----------------------------------------------- |
| `PER_KEY_GAP`     | 3s      | Minimum delay between uses of the same key      |
| `SUCCESS_SLEEP`   | 1s      | Delay between successful requests               |
| `RATE_SLEEP_FAST` | 30s     | Cooldown after a single `429`                   |
| `RATE_SLEEP_LONG` | 180s    | Cooldown after consecutive `429`s               |
| `MAX_429_RETRIES` | 5       | Number of consecutive 429s before long cooldown |

Example:

```bash
export RATE_SLEEP_FAST=20
export PER_KEY_GAP=5
./otx.sh -d example.com -k otx_tokens.txt -t url
```

---

##  Troubleshooting

| Issue                        | Possible Cause / Fix                              |
| ---------------------------- | ------------------------------------------------- |
| `No data collected`          | Domain has no OTX records, typo, or invalid key   |
| `HTTP 429 Too Many Requests` | Reduce `-l`, add more keys, or increase cooldowns |
| `Missing dependency`         | Install missing package using apt or brew         |

---

##  Security Notes

* Never commit API keys to your repository.
* Store them in a private file (e.g., `otx_tokens.txt`) and `.gitignore` it.
* Treat all output logs as **sensitive recon artifacts**.

---

## Author

**Sub-O-TX** — by [Mihir Limbad (0xAshura)](https://github.com/0xAshura)

---

##  License

MIT License — you are free to use, modify, and distribute with attribution.


