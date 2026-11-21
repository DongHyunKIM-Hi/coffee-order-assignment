#!/usr/bin/env bash
# 카페 주문 시스템 - 도전 요구사항 시나리오 자동 확인
#
# README 4장의 도전 요구사항(동시성, 데이터 일관성 등)이 지켜지는지 한 번에 확인합니다.
# 각 시나리오를 [통과]/[실패]로 색을 입혀 보여 주고, 마지막에 "통과 N/M"을 출력합니다.
#
# 사용법
#   1) MySQL과 Redis를 띄웁니다(정답 구성 기준: docker compose up -d --wait).
#   2) 구현한 서버를 8080 포트로 실행합니다:  ./gradlew bootRun
#   3) bash check-scenarios.sh
#
# 필요한 것
#   - 실행 중인 MySQL과 Redis (compose). 데이터 일관성(7일 범위) 확인에서 DB에 직접 접근합니다.
#   - 서버가 8080에서 실행 중일 것 (다른 포트는 SERVER_URL로 지정).
#   - curl, jq, docker.
#
# 이 스크립트가 가정하는 API (정답 서버 기준, README의 명세와 다르면 맞게 고쳐 쓰세요)
#   GET  /api/menus                      -> 200 [{"menuId","name","price"}, ...]
#   POST /api/points/charge {userId,amount} -> 200 {"userId","balance"}
#   GET  /api/points/{userId}            -> 200 {"userId","balance"}
#   POST /api/orders {userId,menuId}     -> 201 {"...","remainingPoint",...} / 409 / 404
#   GET  /api/menus/popular              -> 200 [{"rank","menuId","name","price","orderCount"}, ...]
#
# - 메뉴 ID와 가격은 하드코딩하지 않고 GET /api/menus로 조회해서 씁니다.
# - 실행할 때마다 새 사용자 ID($RANDOM$RANDOM)를 쓰므로 서버를 재시작하지 않고 몇 번이든 돌릴 수 있습니다.
# - 7일 범위 확인은 과거 주문을 DB에 직접 넣고, 인기 메뉴 집계 캐시(Redis)를 비워 주문 테이블 집계로
#   되돌아가게 한 뒤 확인합니다. MySQL/Redis 컨테이너는 실행 중인 것을 자동으로 찾아 쓰고,
#   다른 컨테이너를 쓰려면 MYSQL_CONTAINER/REDIS_CONTAINER 환경변수로 지정합니다.
# - 윈도우(Git Bash 등)에서 curl이 줄 끝에 캐리지리턴(\r)을 붙여도 비교가 깨지지 않도록 응답을 받는 곳에서 \r을 제거합니다.

S=${SERVER_URL:-http://localhost:8080}
MYSQL_CONTAINER=${MYSQL_CONTAINER:-$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i -m1 mysql)}
REDIS_CONTAINER=${REDIS_CONTAINER:-$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i -m1 redis)}
DB_NAME=${DB_NAME:-coffee}
H='Content-Type: application/json'

# 직접 넣은 과거 주문을 표시하는 사용자 ID (끝나면 지웁니다)
MARK_USER=999000001

res1=""; res2=""; res3=""; res4=""; res5=""; res6=""
res7=""; res8=""; res9=""; res10=""; res11=""; res12=""
PASS=0; FAIL=0

ok(){ eval "res$1=\"\$(printf '\033[32m[통과]\033[0m %-28s %s' \"$2\" \"$3\")\""; PASS=$((PASS+1)); }
no(){ eval "res$1=\"\$(printf '\033[31m[실패]\033[0m %-28s %s — %s' \"$2\" \"$3\" \"$4\")\""; FAIL=$((FAIL+1)); }

code(){ curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@" | tr -d '\r'; }
charge(){ curl -s --max-time 20 -X POST "$S/api/points/charge" -H "$H" -d "{\"userId\":$1,\"amount\":$2}"; }
chargecode(){ curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$S/api/points/charge" -H "$H" -d "{\"userId\":$1,\"amount\":$2}" | tr -d '\r'; }
order(){ curl -s --max-time 20 -X POST "$S/api/orders" -H "$H" -d "{\"userId\":$1,\"menuId\":$2}"; }
ordercode(){ curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$S/api/orders" -H "$H" -d "{\"userId\":$1,\"menuId\":$2}" | tr -d '\r'; }
bal(){ curl -s --max-time 20 "$S/api/points/$1" | jq -r '.balance // empty'; }
# 인기 메뉴 응답(JSON)에서 특정 메뉴의 주문 횟수. 목록에 없으면 0.
popcount(){ printf '%s' "$1" | jq -r --argjson m "$2" 'map(select(.menuId==$m)) | (.[0].orderCount // 0)'; }
mysqlx(){ docker exec "$MYSQL_CONTAINER" mysql -uroot -proot "$DB_NAME" -N -e "$1" 2>/dev/null; }
# ranking:menu:* 키를 모두 지워 인기 메뉴 집계가 주문 테이블로 폴백하게 만든다.
clear_ranking(){ docker exec "$REDIS_CONTAINER" redis-cli EVAL "local ks=redis.call('keys','ranking:menu:*'); for i=1,#ks do redis.call('del',ks[i]) end; return #ks" 0 >/dev/null 2>&1; }

echo "서버($S)와 MySQL/Redis 연결을 확인합니다..."
[ "$(code "$S/api/menus")" = "000" ] && { echo "서버에 연결할 수 없습니다. ./gradlew bootRun 후 다시 실행해 주세요."; exit 1; }
docker exec "$MYSQL_CONTAINER" true 2>/dev/null   || { echo "MySQL 컨테이너($MYSQL_CONTAINER)에 접근할 수 없습니다. docker compose up -d 후 다시 실행해 주세요."; exit 1; }
docker exec "$REDIS_CONTAINER" true 2>/dev/null   || { echo "Redis 컨테이너($REDIS_CONTAINER)에 접근할 수 없습니다. docker compose up -d 후 다시 실행해 주세요."; exit 1; }

# 메뉴 ID와 가격을 조회해서 쓴다 (하드코딩 금지).
MENUS=$(curl -s --max-time 20 "$S/api/menus")
M0=$(printf '%s' "$MENUS"  | jq -r '.[0].menuId');  P0=$(printf '%s' "$MENUS" | jq -r '.[0].price')
MD=$(printf '%s' "$MENUS"  | jq -r '.[-1].menuId'); PD=$(printf '%s' "$MENUS" | jq -r '.[-1].price')
R=$RANDOM$RANDOM

# =====================================================================
# 기능
# =====================================================================

# S1. 메뉴 조회 200
c=$(code "$S/api/menus")
n=$(printf '%s' "$MENUS" | jq -r 'length' 2>/dev/null)
if [ "$c" = "200" ] && [ -n "$M0" ] && [ "$M0" != "null" ] && [ "${n:-0}" -ge 1 ]; then
  ok 1 "메뉴 조회" "200, ${n}개 (가격 조회 완료)"
else no 1 "메뉴 조회" "200/목록" "응답 $c, 목록 ${n:-없음}"; fi

# S2. 충전 후 잔액 확인
u="2${R}"
cb=$(charge "$u" 10000 | jq -r '.balance // empty')
gb=$(bal "$u")
if [ "$cb" = "10000" ] && [ "$gb" = "10000" ]; then
  ok 2 "충전 후 잔액 확인" "충전응답 $cb, 조회 $gb"
else no 2 "충전 후 잔액 확인" "잔액 10000" "충전응답 ${cb:-없음}, 조회 ${gb:-없음}"; fi

# S3. 주문 성공 201, 잔액 차감
u="3${R}"
charge "$u" $((P0*2)) >/dev/null
resp=$(curl -s --max-time 20 -w '\n%{http_code}' -X POST "$S/api/orders" -H "$H" -d "{\"userId\":$u,\"menuId\":$M0}" | tr -d '\r')
scode=${resp##*$'\n'}; body=${resp%$'\n'*}
rp=$(printf '%s' "$body" | jq -r '.remainingPoint // empty')
gb=$(bal "$u")
if [ "$scode" = "201" ] && [ "$rp" = "$P0" ] && [ "$gb" = "$P0" ]; then
  ok 3 "주문 성공·잔액 차감" "201, 잔액 $((P0*2))->$gb"
else no 3 "주문 성공·잔액 차감" "201, 잔액 $P0" "상태 $scode, 주문응답잔액 ${rp:-없음}, 조회 ${gb:-없음}"; fi

# S4. 인기 메뉴 조회 200
pres=$(curl -s --max-time 20 "$S/api/menus/popular")
c=$(code "$S/api/menus/popular")
if [ "$c" = "200" ] && printf '%s' "$pres" | jq -e 'type=="array"' >/dev/null 2>&1; then
  ok 4 "인기 메뉴 조회" "200 (배열 응답)"
else no 4 "인기 메뉴 조회" "200/배열" "응답 $c"; fi

# =====================================================================
# 예외
# =====================================================================

# S5. 잔액 부족 409, 차감 안 됨
u="5${R}"
charge "$u" 100 >/dev/null          # 메뉴 가격보다 적게 충전
c=$(ordercode "$u" "$M0")
gb=$(bal "$u")
if [ "$c" = "409" ] && [ "$gb" = "100" ]; then
  ok 5 "잔액 부족 409·차감 없음" "409, 잔액 100 유지"
else no 5 "잔액 부족 409·차감 없음" "409, 잔액 100" "응답 $c, 잔액 ${gb:-없음}"; fi

# S6. 없는 메뉴 404
c=$(ordercode "6${R}" 999999999)
if [ "$c" = "404" ]; then ok 6 "없는 메뉴 404" "404"
else no 6 "없는 메뉴 404" "404" "응답 $c"; fi

# S7. 잘못된 충전 금액 400 (0, 음수, 소수, 한도초과)
c0=$(chargecode "7${R}" 0)
cneg=$(chargecode "7${R}" -5000)
cflt=$(chargecode "7${R}" 10.5)
cmax=$(chargecode "7${R}" 2000000)
if [ "$c0" = "400" ] && [ "$cneg" = "400" ] && [ "$cflt" = "400" ] && [ "$cmax" = "400" ]; then
  ok 7 "잘못된 충전 금액 400" "0/음수/소수/한도초과 모두 400"
else no 7 "잘못된 충전 금액 400" "모두 400" "0=$c0 음수=$cneg 소수=$cflt 한도=$cmax"; fi

# =====================================================================
# 동시성 (핵심)
# =====================================================================

# S8. 3잔 값(3*가격) 충전 후 동시 주문 10건 -> 성공 3건, 잔액 0
u="8${R}"
charge "$u" $((P0*3)) >/dev/null
codes8=$( for i in $(seq 1 10); do ( ordercode "$u" "$M0"; echo ) & done; wait )
s201=$(printf '%s\n' "$codes8" | tr -d '\r' | grep -c '^201$')
gb=$(bal "$u")
if [ "$s201" = "3" ] && [ "$gb" = "0" ]; then
  ok 8 "동시 주문 10건(3잔 값)" "성공 3건, 잔액 0"
else no 8 "동시 주문 10건(3잔 값)" "성공 3건·잔액 0" "성공 ${s201}건, 잔액 ${gb:-없음}"; fi

# S9. 100P 충전 100건 동시 -> 잔액 10,000 (누락 없음)
u="9${R}"
( for i in $(seq 1 100); do chargecode "$u" 100 >/dev/null & done; wait )
gb=$(bal "$u")
if [ "$gb" = "10000" ]; then
  ok 9 "동시 충전 100건(100P)" "잔액 10,000 (누락 없음)"
else no 9 "동시 충전 100건(100P)" "잔액 10,000" "잔액 ${gb:-없음}"; fi

# S10. 다른 사용자 50명 동시 주문 -> 그 메뉴 주문 횟수 증가분 정확히 50
B=$RANDOM$RANDOM
# 50명에게 각각 1잔 값 충전
( for i in $(seq 1 50); do chargecode "${B}0${i}" "$P0" >/dev/null & done; wait )
before=$(popcount "$(curl -s --max-time 20 "$S/api/menus/popular")" "$M0")
( for i in $(seq 1 50); do ordercode "${B}0${i}" "$M0" >/dev/null & done; wait )
after=$(popcount "$(curl -s --max-time 20 "$S/api/menus/popular")" "$M0")
diff=$((after - before))
if [ "$diff" = "50" ]; then
  ok 10 "다른 사용자 50명 동시 주문" "인기 집계 증가분 50 ($before->$after)"
else no 10 "다른 사용자 50명 동시 주문" "증가분 50" "증가분 $diff ($before->$after)"; fi

# =====================================================================
# 데이터 일관성
# =====================================================================

# S11. 커밋된 주문만 집계 (실패한 주문은 인기 집계에 안 들어감)
# 3잔 값만 충전하고 같은 메뉴를 5번 순서대로 주문 -> 3건 성공(커밋), 2건 409(롤백).
# 인기 집계에는 커밋된 3건만 잡혀야 한다.
# 인기 메뉴 API는 상위 3개만 돌려주므로, 순위에서 밀리지 않는 메뉴(S8·S10에서 이미 많이 주문한 M0)로
# 측정한다. 주문이 적은 메뉴를 쓰면 목록에 아예 안 나와서 증가분을 읽을 수 없다.
u="11${R}"
charge "$u" $((P0*3)) >/dev/null
before11=$(popcount "$(curl -s --max-time 20 "$S/api/menus/popular")" "$M0")
succ=0; fail=0
for i in 1 2 3 4 5; do
  c=$(ordercode "$u" "$M0")
  [ "$c" = "201" ] && succ=$((succ+1))
  [ "$c" = "409" ] && fail=$((fail+1))
done
cnt=$(popcount "$(curl -s --max-time 20 "$S/api/menus/popular")" "$M0")
diff11=$((cnt - before11))
if [ "$succ" = "3" ] && [ "$fail" = "2" ] && [ "$diff11" = "3" ]; then
  ok 11 "커밋된 주문만 집계" "성공 3·실패 2, 집계 증가분 3 (실패 제외)"
else no 11 "커밋된 주문만 집계" "집계 증가분 3" "성공 ${succ}·실패 ${fail}, 증가분 ${diff11} (${before11}->${cnt})"; fi

# S12. 인기 메뉴 최근 7일 범위 (8일 전 주문 제외)
# 집계 캐시(Redis)를 비워 주문 테이블 집계로 폴백시킨 뒤,
# 메뉴 D의 과거 주문을 직접 넣는다: 1일 전 100건(범위 안) + 8일 전 100건(범위 밖).
# 폴백 집계는 범위 안 100건만 세어야 한다.
mysqlx "DELETE FROM coffee_order WHERE user_id = $MARK_USER;"
clear_ranking
mysqlx "INSERT INTO coffee_order (user_id, menu_id, price, ordered_at)
        SELECT $MARK_USER, $MD, $PD, DATE_SUB(NOW(), INTERVAL 1 DAY) FROM menu a, menu b, menu c LIMIT 100;"
mysqlx "INSERT INTO coffee_order (user_id, menu_id, price, ordered_at)
        SELECT $MARK_USER, $MD, $PD, DATE_SUB(NOW(), INTERVAL 8 DAY) FROM menu a, menu b, menu c LIMIT 100;"
dcount=$(popcount "$(curl -s --max-time 20 "$S/api/menus/popular")" "$MD")
mysqlx "DELETE FROM coffee_order WHERE user_id = $MARK_USER;"
if [ "$dcount" = "100" ]; then
  ok 12 "인기 메뉴 최근 7일 범위" "범위 안 100건만 집계 (8일 전 100건 제외)"
else no 12 "인기 메뉴 최근 7일 범위" "집계 100" "집계 ${dcount} (8일 전 주문이 섞였거나 폴백 실패)"; fi

# =====================================================================
# 결과
# =====================================================================
echo
echo "================= 시나리오 확인 결과 ================="
echo "[기능]"
for i in 1 2 3 4; do eval "printf '  %b\n' \"\$res$i\""; done
echo "[예외]"
for i in 5 6 7; do eval "printf '  %b\n' \"\$res$i\""; done
echo "[동시성]"
for i in 8 9 10; do eval "printf '  %b\n' \"\$res$i\""; done
echo "[데이터 일관성]"
for i in 11 12; do eval "printf '  %b\n' \"\$res$i\""; done
echo "====================================================="
echo "통과 $PASS / 12"
[ "$FAIL" -gt 0 ] && echo "실패한 시나리오는 README 3~4장(필수·도전 요구사항)에서 해당 항목을 확인해 주세요."
exit 0
