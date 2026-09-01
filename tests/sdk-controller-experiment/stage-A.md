# SDK controller experiment stage A

## Worker command

```sh
echo hello > /tmp/sdk-exp-A.txt
```

## Verifier command

```sh
test "$(cat /tmp/sdk-exp-A.txt)" = hello
```

