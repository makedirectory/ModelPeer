# Publish v0.1.0

From this directory:

```bash
git init
git add .
git commit -m 'feat: release model-peer v0.1.0'

gh repo create model-peer --public --source=. --remote=origin --push

git tag -a v0.1.0 -m 'Model Peer v0.1.0'
git push origin v0.1.0
```

Then create the GitHub release:

```bash
gh release create v0.1.0 \
  --title 'Model Peer v0.1.0' \
  --notes-file RELEASE_NOTES.md
```

GitHub will generate source archives automatically. If you also want to attach the
prebuilt release ZIP, upload `model-peer-v0.1.0.zip` from the parent directory in
the GitHub release UI or with `gh release upload`.

After the repository exists, replace `YOUR_GITHUB_USERNAME` in the README one-line
installer examples with your GitHub username or organization.
