#!/bin/bash
# _____              _____                   
#|  __ \            / ____|                  
#| |  | |_   _  ___| (___  _   _ _ __  _ __  
#| |  | | | | |/ _ \\___ \| | | | '_ \| '_ \ 
#| |__| | |_| | (_) |___) | |_| | |_) | |_) |
#|_____/ \__,_|\___/_____/ \__,_| .__/| .__/ 
#                               | |   | |    
#                               |_|   |_|    
export PATH=$PATH:'/opt/mssql-tools/bin'
DATE=$(date '+%F')
BACKUP_EXTENTION='bak'
DESTINATION_PATH='/var/opt/mssql/backup'
TEMP_PATH='/tmp'
LOG_PATH='/var/log/mssql/backup'
DB_USER='user'
DB_PASSWORD='password'
KEEP_LAST_DAILY=30
KEEP_LAST_WEEKLY=8
KEEP_LAST_MONTHLY=12
LOG="$LOG_PATH/$DATE".log
declare -a DBS=('db1' 'db2')
WARNING=0
ERROR=0
#email
EMAIL_FROM='MSSQL <backup@example.com>'
EMAIL_SERVER='example.com'
EMAIL_USER='backup@example.com'
EMAIL_PASSWORD='yourstrongpassword'
EMAIL_TLS='tls=auto'
EMAIL_DBENGINE='MSSQL'
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
	DB_NAME="$1"
	writelog "Starting back up and validate procedure of $DB_NAME database"
	mkdir -p "$DESTINATION_PATH/$DB_NAME/DAILY"
	BACKUP_PATH="$DESTINATION_PATH/$DB_NAME/DAILY/$DATE.$BACKUP_EXTENTION"
	writelog "Creating $BACKUP_EXTENTION file"
	sqlcmd -S localhost -U "$DB_USER" -P "$DB_PASSWORD" -Q "BACKUP DATABASE [$DB_NAME] TO DISK = N'$BACKUP_PATH' WITH NOFORMAT, NOINIT, NAME = '$DB_NAME', SKIP, NOREWIND, NOUNLOAD, STATS = 10"
	if [[ $? -ne 0 ]]
	then
		ERROR=$((ERROR + 1))
		writelog 'Some error(s) occured during backup creation!' 'ERROR'
		writelog 'Exit current DB processing' 'Warn'
		return 1
	fi
	writelog 'Deleting old daily backups'
	ls -t "$DESTINATION_PATH/$DB_NAME/DAILY" | awk "NR>$KEEP_LAST_DAILY" | xargs rm -f
	ln -sf $(realpath --relative-to="$DESTINATION_PATH/$DB_NAME" "$BACKUP_PATH") "$DESTINATION_PATH/$DB_NAME/recent-backup.$BACKUP_EXTENTION"
#	cd "$DESTINATION_PATH/$DB_NAME"
#	ln -sf "DAILY/$DATE.$BACKUP_EXTENTION" 'recent-backup.$BACKUP_EXTENTION'
	if [[ $(date +%u) -eq 7 ]]
	then
		writelog 'Copying week backup'
		mkdir -p "$DESTINATION_PATH/$DB_NAME/WEEKLY"
		cp -p "$BACKUP_PATH" "$DESTINATION_PATH/$DB_NAME/WEEKLY"
		writelog 'Deleting old weekly backups'
		ls -t "$DESTINATION_PATH/$DB_NAME/WEEKLY" | awk "NR>$KEEP_LAST_WEEKLY" | xargs rm -f
	fi
	if [[ $(date -d "$date + 1week" +%d%a) =~ 0[1-7]Sun ]]
	then
		writelog 'Copying month backup'
		mkdir -p "$DESTINATION_PATH/$DB_NAME/MONTHLY"
		cp -p "$BACKUP_PATH" "$DESTINATION_PATH/$DB_NAME/MONTHLY"
		writelog 'Deleting old monthly backups'
		ls -t "$DESTINATION_PATH/$DB_NAME/MONTHLY" | awk "NR>$KEEP_LAST_WEEKLY" | xargs rm -f
	fi
	writelog "Backup size $(du -h $BACKUP_PATH | awk '{print $1}')"
}
function checkmount() {
	findmnt "$DESTINATION_PATH" >/dev/null;
}
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
	for DB in "${DBS[@]}"
	do
		createbackup "$DB"
	done
fi
echo "</tbody></table><p id=\"Warn\">Warnings count - $WARNING</p><p id=\"Error\">Errors count - $ERROR</p><p>Free space on backup drive: $(df -Ph $DESTINATION_PATH | tail -1 | awk '{print $4}')</p></div></body></html>" >> "$LOG"
cat "$LOG" | sendEmail -f "$EMAIL_FROM" -t $EMAIL_TO -s "$EMAIL_SERVER" -q -u "$EMAIL_DBENGINE backup finished: $([[ $ERROR -eq 0 ]] && echo OK || echo ERRORS)" -xu "$EMAIL_USER" -xp "$EMAIL_PASSWORD" -o "$EMAIL_TLS"
exit $ERROR
