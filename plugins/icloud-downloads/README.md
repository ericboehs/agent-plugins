# icloud-downloads

Copy files to iCloud Downloads for easy access on iPhone/iPad.

## Installation

```bash
claude plugin install icloud-downloads --marketplace ericboehs/agent-plugins
```

## Usage

- `/copy-to-icloud-downloads` — Copy a file from the current session to iCloud Downloads

The skill uses conversation context to figure out which file you mean. Files are copied to `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/` and sync via iCloud to the Files app.
