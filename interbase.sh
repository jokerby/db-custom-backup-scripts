#!/bin/bash
# _____              _____                   
#|  __ \            / ____|                  
#| |  | |_   _  ___| (___  _   _ _ __  _ __  
#| |  | | | | |/ _ \\___ \| | | | '_ \| '_ \ 
#| |__| | |_| | (_) |___) | |_| | |_) | |_) |
#|_____/ \__,_|\___/_____/ \__,_| .__/| .__/ 
#                               | |   | |    
#                               |_|   |_|    
export PATH=$PATH:'/opt/interbase/bin'
DATE=$(date '+%F')
SOURCE_PATH='/var/lib/interbase'
DB_EXTENTION='gdb'
DESTINATION_PATH='/var/lib/backup'
TEMP_PATH='/tmp'
LOG_PATH='/var/log/interbase'
DB_USER='user'
DB_PASSWORD='password'
KEEP_LAST_DAILY=30
KEEP_LAST_WEEKLY=8
KEEP_LAST_MONTHLY=12
LOG="$LOG_PATH/$DATE".log
WARNING=0
ERROR=0
#email
EMAIL_FROM='Interbase <backup@example.com>'
EMAIL_SERVER='example.com'
EMAIL_USER='backup@example.com'
EMAIL_PASSWORD='yourstrongpassword'
EMAIL_TLS='tls=auto'
EMAIL_DBENGINE='Interbase'
EMAIL_HEADER='My company name'
EMAIL_TO='first@example.com second@example.com'

function writelog {
	if [ -n "$1" ]
	then
		MESSAGE="$1"
	else
		read MESSAGE
	fi
	LEVEL=${2:-Info}
	echo "<tr><td>$(date '+%F %T')</td><td>$LEVEL</td><td><p id=\"$LEVEL\">$MESSAGE</p></td></tr>" >> "$LOG"
	echo $MESSAGE
}
function createbackup {
	DB_PATH="$1"
	writelog "Starting back up and validate procedure of $DB_PATH database"
	DB_NAME="$(basename $DB_PATH .gdb)"
	mkdir -p "$DESTINATION_PATH/$DB_NAME/DAILY"
	GBK_PATH="$DESTINATION_PATH/$DB_NAME/DAILY/$DATE.gbk"
	TEMP_DB_PATH="$TEMP_PATH/$DB_NAME.gdb"
	writelog "Creating gbk file"
	gbak -USER "$DB_USER" -PASSWORD "$DB_PASSWORD" -BACKUP_DATABASE "$DB_PATH" "$GBK_PATH"
	if [[ $? -ne 0 ]]
	then
		ERROR=$((ERROR + 1))
		writelog 'Some error(s) occured during backup creation!' 'ERROR'
		writelog 'Exit current DB processing' 'Warn'
		return 1
	fi
#	chmod 600 "$GBK_PATH"
#	chown interbase:interbase "$GBK_PATH"
	writelog "Unpacking gbk file for test purpose"
	gbak -USER "$DB_USER" -PASSWORD "$DB_PASSWORD" -REPLACE_DATABASE -PAGE_SIZE 8192 "$GBK_PATH" "$TEMP_DB_PATH"
	if [[ $? -ne 0 ]]
	then
		ERROR=$((ERROR + 1))
		writelog 'Some error(s) occured during backup restoration!' 'ERROR'
		writelog 'Exit current DB processing' 'Warn'
		return 1
	fi
	writelog 'Validating unpacked database'
	VALIDATE_LOG="$(gfix -user "$DB_USER" -password "$DB_PASSWORD" -validate -full -no_update "$TEMP_DB_PATH")"
	GREP_LOG_FOR_ERRORS="$(grep errors <<< $VALIDATE_LOG)"
	if [[ "$GREP_LOG_FOR_ERRORS" =~ .*errors.* ]]
	then
		ERROR=$((ERROR + $(echo "$GREP_LOG_FOR_ERRORS" | wc -l)))
		writelog 'Error(s) occured during backup validation!' 'ERROR'
		writelog "$GREP_LOG_FOR_ERRORS" 'ERROR'
	fi
	rm "$TEMP_DB_PATH"
	writelog 'Deleting old daily backups'
	ls -t "$DESTINATION_PATH/$DB_NAME/DAILY" | awk "NR>$KEEP_LAST_DAILY" | xargs rm -f
	ln -sf $(realpath --relative-to="$DESTINATION_PATH/$DB_NAME" "$GBK_PATH") "$DESTINATION_PATH/$DB_NAME/recent-backup.gbk"
#	cd "$DESTINATION_PATH/$DB_NAME"
#	ln -sf "DAILY/$DATE.sql" 'recent-backup.sql'
	if [[ $(date +%u) -eq 7 ]]
	then
		writelog 'Copying week backup'
		mkdir -p "$DESTINATION_PATH/$DB_NAME/WEEKLY"
		cp -p "$GBK_PATH" "$DESTINATION_PATH/$DB_NAME/WEEKLY"
		writelog 'Deleting old weekly backups'
		ls -t "$DESTINATION_PATH/$DB_NAME/WEEKLY" | awk "NR>$KEEP_LAST_WEEKLY" | xargs rm -f
	fi
	if [[ $(date -d "$date + 1week" +%d%a) =~ 0[1-7]Sun ]]
	then
		writelog 'Copying month backup'
		mkdir -p "$DESTINATION_PATH/$DB_NAME/MONTHLY"
		cp -p "$GBK_PATH" "$DESTINATION_PATH/$DB_NAME/MONTHLY"
		writelog 'Deleting old monthly backups'
		ls -t "$DESTINATION_PATH/$DB_NAME/MONTHLY" | awk "NR>$KEEP_LAST_WEEKLY" | xargs rm -f
	fi
	writelog "Backup size $(du -h $GBK_PATH | awk '{print $1}')"
}
function checkmount() {
	findmnt "$DESTINATION_PATH" >/dev/null;
}
rm -f "$TEMP_PATH"/*."$DB_EXTENTION"
mkdir -p "$LOG_PATH"
echo '<!DOCTYPE html><html><head><title>'"$EMAIL_HEADER"' Backup Report for '"$EMAIL_DBENGINE"'</title><style> body { font-family: Verdana, Geneva, Arial, Helvetica, sans-serif; font-size: 12px } h3{ clear: both; font-size: 150%; margin-left: 20px;margin-top: 30px; } table { padding: 15px 0 20px; width: 100%; text-align: left; } td, th { padding: 0 20px 0 0; margin 0; text-align: left; } th { margin-top: 15px } #Report { width: 100%; } #Info { color: green } #Warn { color: orange } #Error { color: red } </style></head><body><div id="Report"><p><h3>'"$EMAIL_HEADER"' Backup Report for '"$EMAIL_DBENGINE"'</p></h3><table id="summary"><tbody><tr><td>Time</td><td>Type</td><td>Message</td></tr>' > "$LOG"
DESTINATION_OK=true
if ! checkmount
then
	writelog 'Mountpoint not mounted. Trying to fix' 'Warn'
	WARNING=$((WARNING + 1))
	if ! mount "$DESTINATION_PATH"
	then
		writelog 'Mountpoint cant been mount. Exit processing' 'Error'
		ERROR=$((ERROR + 1))
		DESTINATION_OK=false
	fi
fi
if $DESTINATION_OK
then
	for DB in "$SOURCE_PATH"/*."$DB_EXTENTION"
	do
		createbackup "$DB"
	done
fi
echo "</tbody></table><p id=\"Warn\">Warnings count - $WARNING</p><p id=\"Error\">Errors count - $ERROR</p><p>Free space on backup drive: $(df -Ph $DESTINATION_PATH | tail -1 | awk '{print $4}')</p></div></body></html>" >> "$LOG"
cat "$LOG" | sendEmail -f "$EMAIL_FROM" -t $EMAIL_TO -s "$EMAIL_SERVER" -q -u "$EMAIL_DBENGINE backup finished: $([[ $ERROR -eq 0 ]] && echo OK || echo ERRORS)" -xu "$EMAIL_USER" -xp "$EMAIL_PASSWORD" -o "$EMAIL_TLS"
exit $ERROR
