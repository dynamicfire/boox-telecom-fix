#!/system/bin/sh
# Enable telephony calling feature (from v2.0 calling fix)
LOGFILE=/data/local/tmp/telecom-fix.log
echo "$(date): Boox telecom+sms fix starting..." > $LOGFILE

# Wait for telecom service
MAX_WAIT=60
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if service check telecom 2>/dev/null | grep -q "not found"; then
        sleep 2
        WAITED=$((WAITED + 2))
    else
        break
    fi
done
echo "$(date): telecom service ready after ${WAITED}s" >> $LOGFILE

# Enable calling feature
RESULT=$(service call telecom 60 i32 1 2>&1)
echo "$(date): service call telecom 60 result: $RESULT" >> $LOGFILE

echo "$(date): SMS fix applied via telephony-common.jar overlay" >> $LOGFILE
echo "$(date): Fix complete" >> $LOGFILE
