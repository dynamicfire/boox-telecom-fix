#!/system/bin/sh
LOGFILE=/data/local/tmp/telecom-fix.log
echo "$(date): Boox telecom+sms fix v1.3 starting..." > $LOGFILE

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

# Fix 1: Enable outgoing calls
RESULT=$(service call telecom 60 i32 1 2>&1)
echo "$(date): service call telecom 60 result: $RESULT" >> $LOGFILE

# Fix 2: Enable incoming calls
# Boox's addNewIncomingCall() blocks incoming calls when default dialer is org.codeaurora.dialer
# Switching default dialer to any other package bypasses this check (package doesn't need to exist)
DIALER_RESULT=$(telecom set-default-dialer com.google.android.dialer 2>&1)
echo "$(date): set-default-dialer result: $DIALER_RESULT" >> $LOGFILE

# Fix 3: SMS enabled via telephony-common.jar overlay (system/framework)
echo "$(date): SMS fix applied via telephony-common.jar overlay" >> $LOGFILE
echo "$(date): Fix complete" >> $LOGFILE
