#!/bin/sh

# $Id: backup_afs.sh,v 1.37 2007-02-01 15:42:10 turbo Exp $

cd /

# --------------
# Set some default variables
AFSSERVER="aurora.bayour.com"
AFSCELL="bayour.com"
CURRENTDATE=`date +"%Y%m%d"`
MAXSIZE=2000000

# Don't change this, it's set with commandline options
BACKUP_TYPE="all"

# --------------
# FUNCTION: Find the LATEST modification date of a file
last_modified () {
    FILE=`echo $1 | sed -e 's@full-@*@' -e 's@incr-@*@'`
    set -- `/bin/ls -t $FILE* 2> /dev/null | sed 's@ .*@@'`
    FILE=$1

    if [ -n "$FILE" ]; then
	set -- `/bin/ls -l --full-time $FILE`
	shift ; shift ; shift ; shift ; shift
	mon=`echo $2 | sed -e 's@Jan@01@' -e 's@Feb@02@' -e 's@Mar@03@' -e 's@Apr@04@' \
	    -e 's@May@05@' -e 's@Jun@06@' -e 's@Jul@07@' -e 's@Aug@08@' -e 's@Sep@09@' \
	    -e 's@Oct@10@' -e 's@Nov@11@' -e 's@Dec@12@'`
	DATE="$mon/$3/$5"
    else
	DATE=""
    fi
}

# --------------
# FUNCTION: Check if volume have been modified within the last 24 hours
#	    Returns 1 if it have, 0 if not
get_vol_mod () {
    if [ "$BACKUP_TYPE" = "all" ]; then
	# Backup this volume wether it's been modified resently or not: --all specified!
	return 1
    fi

    # Examine volume - when was volume last modified?
    local last=`vos examine $1 $LOCALAUTH | grep 'Last Update' | sed 's@.*Update @@'`

    if [ "$last" = "Never" -o "$FORCE_BACKUP" = 1 ]; then
	return 1
    else
	# What's that in UNIX std format (seconds since Jan 1, 1970)?
	local modified=`date -d "$last" +"%s"`

	# What's the current UNIX std time (- 24h)?
	local now=`date +"%s"`
	now=`expr $now - \( 60 \* 60 \* 24 \)`

	if [ $modified -ge $now ]; then
	    return 1
	else
	    return 0
	fi
    fi
}

# --------------
# FUNCTION: Find the mountpoint of the volume
get_vol_mnt () {
    local vol="`echo $1 | sed 's@.*\.@@'`"
    local VOL

    MNTPOINT="/afs/$AFSCELL/`(cd /afs/$AFSCELL && find -type d -name '[a-zA-Z0-9]*' -exec find {} -type d -name "$vol" \;)`"
    if [ -z "$MNTPOINT" ]; then
	# Bummer! Not found the 'easy' way, guess... (!!!)
	MNTPOINT="/afs/$AFSCELL/`echo $1 | sed 's@\.@/@g'`"
    else
	# Double check that the mountpoint really IS the volume we're checking!
	VOL=`fs examine $MNTPOINT | head -n1 | sed 's@.* @@'`
	if [ ! "$VOL" = "$1" ]; then
	    echo "Mountpoint and volume don't match. -> '$VOL != $1' ($MNTPOINT)" > /dev/stderr
	    exit 1
	fi
    fi
}

# --------------
# FUNCTION: Find the partition the volume is on
get_vol_part () {
    PART=`vos examine $1 $LOCALAUTH | sed 1d | head -n1 | sed 's@.*/@/@'`
    if [ -z "$PART" ]; then
	# Could not find the partition, try again
	PART=`vos examine $vol $LOCALAUTH | egrep 'server .* partition .* RW Site' | sed -e 's@.*/@/@' -e 's@ .*@@'`
    fi

    if [ -z "$PART" ]; then
	# Could not find the partition, DIE, DIE, DIE!!!
	echo "Can't find the partition for the volume!"
	exit 255
    else
	[ -n "$action" -o -n "$verbose" ] && printf " %-30s Partition for volume $volume is $PART\n" " "
    fi
}

# --------------
# FUNCTION: Get the size of the volume
get_vol_size () {
    SIZE=""
    set -- `vos examine $1 $LOCALAUTH | head -n1`
    SIZE=$4
}

# --------------
# FUNCTION: Mount the backup volume
mount_backup_volume () {
    local vol="$1"
    local dir="$2"

    [ -z "$dir" ] && dir="/afs/$AFSCELL"

    if [ "$dir" = "/afs/$AFSCELL" ]; then
	OLDFILES="/afs/$AFSCELL/OldFiles_`echo $vol`-`echo $CURRENTDATE`"
    else
	OLDFILES="$dir/OldFiles_$CURRENTDATE"
    fi

    # 'Mount' the volume in the users homedirectory
    if [ -d "$OLDFILES" ]; then
	# Todays OldFiles also exists, remove the mount
	$action fs rmmount "$OLDFILES"
    fi

    $action fs mkmount "$OLDFILES" $vol.backup
}

# --------------
create_backup_volume () {
    local vol="$1"

    # Check to see if the volume exists
    if ! vos examine $vol > /dev/null 2>&1; then
	RES="1"
    else
	if [ -z "$action" ]; then
	    if [ "$BACKUP_VOLUMES" -gt 0 ]; then
		[ -n "$verbose" ] && printf "  %-30sCreating backup volume...\n" " "
		RES=`vos backup $volume $LOCALAUTH 2>&1`
	    else
		# Make sure that the backup volume actually exists!
		if ! vos examine $vol\.backup > /dev/null 2>&1; then
		    printf "  %-30sForcing creation of backup volume (doesn't exist!)\n" " "
		    RES=`vos backup $volume $LOCALAUTH 2>&1`
		else
		    # Fake this so that the rest of the code understands
		    # See call to create_backup_volume() in do_backup()
		    [ -n "$verbose" ] && printf "  %-30sSkipping creating of backup volume as requested...\n" " "
		    RES="Created backup volume for $volume"
		fi
	    fi
	else
	    [ -n "$verbose" ] && printf "  %-30sCreating backup volume...\n" " "
	    $action vos backup $volume $LOCALAUTH
	    RES="Created backup volume for $volume"
	fi
    fi
}

# --------------
# NOTE:  Don't backup if the backup file already exists!
# NOTE2: Ehm... Yes we should. If --force is given, then overwrite file(s)!
dump_volume () {
    local orig=$1
    local vol="$orig".backup
    local file="$2"

    if [ $SIZE -ge $MAXSIZE ]; then
	# If the volume is bigger than 2Gb, dump in section using 'split'.

	if [ -f $file".aa" -a "$FORCE_BACKUP" -lt 1 ]; then
	    [ -n "$verbose" ] && printf "  %-30sAlready backed up...\n" " "
	    RES=0
	    return 0
	else
	    if [ -n "$action" ]; then
		RES=`$action vos dump -id $vol -server ${AFSSERVER:-localhost} \
		    -partition $PART $TIMEARG $LOCALAUTH 2> /dev/null \| split -b1024m - $file. 2>&1`
	    else
		RES=`vos dump -id $vol -server ${AFSSERVER:-localhost} \
		    -partition $PART $TIMEARG $LOCALAUTH 2> /dev/null | split -b1024m - $file. 2>&1`
	    fi
	fi
    else
	if [ -f $file -a "$FORCE_BACKUP" -lt 1 ]; then
	    [ -n "$verbose" ] && printf "  %-30sAlready backed up...\n" " "
	    RES=0
	    return 0
	else
	    RES=`$action vos dump -id $vol -server ${AFSSERVER:-localhost} \
		-partition $PART $TIMEARG -file $file $LOCALAUTH 2>&1`
	fi
    fi
}

# --------------
do_backup () {
    local volume
    local BACKUPFILE
    local TIMEARG
    local ERROR

    [ -n "$verbose" ] && echo "Backing up volumes:"
    for volume in $VOLUMES; do
	if ! get_vol_mod $volume; then
	    # Backup the volume, it have been modified with the last 24 hours
	    printf "  %-30sstart = `date +"%Y%m%d %H:%M:%S"`\n" $volume
	    START=`date +"%s"`

	    # Find the 'mountpoint' of the volume
	    [ "$MOUNT" -gt 0 ] && get_vol_mnt $volume
	    
	    # Create the backup volume
	    create_backup_volume $volume
	    
	    # Catch errors from the backup volume creation
	    if ! echo $RES | grep -q 'Created backup volume for'; then
		# FAIL: Could not create backup volume
		[ "$RES" != 1 ] && echo -n "Could not create backup volume for '$volume' - "
		
		if echo $RES | grep -q 'VLDB: no such entry'; then
		    # FAIL: Volume don't exists
		    echo "no such volume."
		elif echo $RES | grep -q 'VLDB: no permission access for call'; then
		    # FAIL: Not enough access rights
		    echo "permission denied."
		elif echo $RES | grep -q 'VLDB: vldb entry is already locked'; then
		    # FAIL: Volume database locked
		    echo "Trying to unlock the volume so we can try again"
		    
		    vos unlock $volume $LOCALAUTH > /dev/null 2>&1
		    
		    # Try to backup this volume later...
		    MISSING_VOLUMES="$MISSING_VOLUMES $volume"
		elif echo $RES | grep -q 'VOLSER: volume is busy'; then
		    # FAIL: Volume is busy
		    echo "volume is busy."
		    
		    # Double check that there IS such a volume
		    if vos listvol ${AFSSERVER:-localhost} -quiet $LOCALAUTH | grep -q ^$volume; then
			# No such volume - Is there a $volume.readonly we can use?
			if vos listvol ${AFSSERVER:-localhost} -quiet $LOCALAUTH | grep -q ^$volume.readonly; then
			    # There is a readonly (replica) volume.
			    echo "The volume '$volume' don't exists (anymore!?), but the '$volume.readonly' does..."
			    TMPFILE=`tempfile -d $BACKUPDIR -p vol.`
			    
			    # Dump the volume into a temporary file
			    $action vos dump common.source.kernels.readonly -file $TMPFILE
			    
# TODO: Is this safe? Will it ever happen?
#			    # Restore the volume
#			    $action vos restore -server ${AFSSERVER:-localhost} -partition vicepb \
#				-name $volume -file $TMPFILE -id $volume -overwrite full \
#				$LOCALAUTH
#				
#			    # Update the database
#			    $action fs checkv
#			    
#			    # Try to create the backup volume again
#			    create_backup_volume $volume

			    # Catch an error. Unfortunatly it's to cumbersome to do all 
			    # the previous tests again. I wish there WHERE a goto in sh!
			    if ! echo $RES | grep -q 'Created backup volume for'; then
				echo "Could not create backup volume for '$volume' -"
				echo "Error message:" ; echo "$RES"
			    fi
			fi
		    fi
		    
		    # Try to backup this volume later...
		    MISSING_VOLUMES="$MISSING_VOLUMES $volume"
		elif echo $RES | grep -q 'Volume needs to be salvaged' ||
		    echo $RES | grep -q 'Could not re-clone backup volume'
		then
		    # ERROR
		    # We might get the following error from this:
		    #
		    #[papadoc.root]# vos backup user.malin $LOCALAUTH
		    #Could not re-clone backup volume 536871049
		    #: Invalid argument
		    #Error in vos backup command.
		    #: Invalid argument
		    #
		    #[papadoc.pts/6]$ tail -f /var/log/openafs/VolserLog -n0
		    #Mon Oct 28 09:47:53 2002 1 Volser: Clone: The "recloned" volume must be a read only volume; aborted
		    # FAILED - salvage volume
		
		    # Do the salvage TWICE (just to be safe)!
		    i=0 ; while [ "$i" -lt 2 ]; do
			echo "Trying to salvage the volume so we can try again"
			bos salvage -server ${AFSSERVER:-localhost} -partition $PART -volume $volume $LOCALAUTH
			
			i=`expr $i + 1`
		    done
		    
		    # Try to backup this volume later...
		    MISSING_VOLUMES="$MISSING_VOLUMES $volume"
		elif [ "$RES" = 1 ]; then
		    # Ignore nonexisting volumes
		    echo -n
		else
		    # Unknown reason
		    echo "just failed for some reason." ; echo "Error message:" ; echo "$RES"
		fi
		
		continue
	    else
		# SUCCESS: Created backup volume
	    
		# Mount the volume on it's mountpoint (VOLUME/OldFiles).
		[ "$MOUNT" -gt 0 ] && mount_backup_volume $volume $MNTPOINT
		
		if [ -z "$ERROR" ]; then
		    # Find the partition the volume is on
		    get_vol_part $volume
		    
		    # Find the size of the volume
		    get_vol_size $volume
		    
		    # Is this a incremental or a full backup? If it's incremental, dump from
		    # last known date
		    if [ "$BACKUP_TYPE" = "incr" ]; then
			BACKUPFILE="$BACKUPDIR/incr-$volume-$CURRENTDATE"
			last_modified "$BACKUPDIR/incr-$volume-"
			
			if [ -n "$DATE" ]; then
			    if [ -n "$verbose" ]; then
				printf " %-30s dump > '$DATE'\n" " "
			    fi
			    TIMEARG="-time $DATE"
			else
			    BACKUPFILE="$BACKUPDIR/full-$volume-$CURRENTDATE"
			fi
		    elif [ "$BACKUP_TYPE" = "all" ]; then
			BACKUPFILE="$BACKUPDIR/full-$volume-$CURRENTDATE"
		    fi
		    
		    dump_volume $volume $BACKUPFILE
		    if [ "$?" != 0 ]; then
			ERROR=2
		    fi
		    
		    if echo $RES | grep -q 'Dumped volume'; then
			# DUMP FAILED - any reason
		
			RES=`echo $RES | sed 's@.* /@/@'`
			[ -n "$verbose" ] && printf " %-30s %s\n" " " $RES
		    fi
		    
		    # ------------------
		    # Restore the backup. It does not matter if the volume exists and is mounted,
		    # it will be removed and then created when using '-overwrite full'...
		    # 	vos restore papadoc /vicepb $volume -file full-$BACKUPFILE -overwrite full
		    # 	vos restore papadoc /vicepb $volume -file incr-$BACKUPFILE -overwrite incremental
		    #
		    # If the volume didn't exist and wasn't mounted:
		    # 	fs mkmount /afs/$AFSCELL/$MOUNTPOINT $volume
		    # 	vos release root.cell
		    # ------------------
		    
		    if [ -z "$ERROR" ]; then
			# Remove the mountpoint
			[ "$MOUNT" -gt 0 ] && $action fs rmmount "$OLDFILES"
			
			if [ "$DELETE_VOLUMES" -gt 0 ]; then
			    # Remove the backup volume
			    if [ -z "$action" ]; then
				[ -n "$verbose" ] && printf "  %-30sRemoving backup volume...\n" " "
				vos remove -id $volume.backup $LOCALAUTH > /dev/null 2>&1 &
			    else
				$action vos remove -id $volume.backup $LOCALAUTH
			    fi
			elif [ -n "$verbose" ]; then
			    # Just for verbose purposes...
			    printf "  %-30sSkipping removal of backup volume as requested...\n" " "
			fi
		    fi
		fi
	    fi

	    END=`date +"%s"`
	    printf "  %-30send   = `date +"%Y%m%d %H:%M:%S"`\n" " "

	    SEC=`expr $END - $START` ; MIN=`expr $SEC / 60`
	    printf "  %-30stook  = $SEC sec (~$MIN min)\n" " "
	    echo
	fi
    done
}

do_echo () {
    local string="`echo $*`"
    printf " %-30s CMD: '%s'\n" " " "$string"
}

# =================================================================

# Don't change this
MOUNT=0 ; BACKUP_VOLUMES=1 ; DELETE_VOLUMES=1 ; FORCE_BACKUP=0

# --------------
# Do we backup odd or even weeks?
ODD=`expr \`date +"%V"\` % 2`
if [ "$ODD" != "1" ]; then
    BACKUPDIR="/var/.backups/Volumes/odd"
else
    BACKUPDIR="/var/.backups/Volumes/even"
fi

if [ ! -d "$BACKUPDIR" ]; then
    mkdir -p $BACKUPDIR
fi

# --------------
# Get the CLI options...
TEMP=`getopt -o Cacdefhimpuv --long all,common,echo,force,help,incr,mount,nocreate-vol,nodelete-vol,public,users,verbose -- "$@"`
eval set -- "$TEMP"
while true ; do
    case "$1" in
	-C|--common)		VOLUMES=common		; shift ;;
	-a|--all)		BACKUP_TYPE=all		; shift ;;
	-c|--nocreate-vol)	BACKUP_VOLUMES=0	; shift ;;
	-d|--nodelete-vol)	DELETE_VOLUMES=0	; shift ;;
	-e|--echo)		action=do_echo		; shift ;;
	-f|--force)		FORCE_BACKUP=1		; shift ;;
	-h|--help)
	    echo "Usage:   `basename $0` [option] [volume]"
	    echo "Options:"
	    echo "	 -C,--common		Backup only the common.* volumes"
	    echo "	 -a,--all		Do a FULL backup (even volumes not changed)"
	    echo "	 -c,--nocreate-vol	Don't create the backup volume(s) before backup"
	    echo "	 -d,--nodelete-vol	Don't delete the backup volume(s) after backup"
	    echo "	 -e,--echo		Don't do anything, just echo the commands"
	    echo "	 -f,--force		Force backup of all specified volumes (ignore last access)"
	    echo "	 -h,--help		Show this help"
	    echo "	 -i,--incr		Do a incremental backup (only changed volumes)"
	    echo "	 -m,--mount		Mount the volumes before doing the backup"
	    echo "	 -p,--public		Backup only the public.* volumes"
	    echo "	 -u,--users		Backup only the user.* volumes"
	    echo "	 -v,--verbose		Explain what's to be done"
	    echo "If volume is given, only backup that/those volumes."
	    echo 
	    exit 0
	    ;;
	-i|--incr)		BACKUP_TYPE=incr	; shift ;;
	-m|--mount)		MOUNT=1			; shift ;;
	-p|--public)		VOLUMES=public		; shift ;;
	-u|--users)		VOLUMES=users		; shift ;;
	-v|--verbose)		verbose=1		; shift ;;
	--)
	    shift
	    if [ -n "$1" ]; then
		if [ -n "$VOLUMES" ]; then
		    EXTRA_VOLUMES="$*"
		else
		    VOLUMES="$*"
		fi
	    fi
	    break
	    ;; 
	*)			echo "Internal error!"	; exit 1 ;;
    esac
done

# --------------
# 'Initialize' AFS access...
ID=`id -u`
if [ "$ID" = "0" ]; then
    LOCALAUTH="-localauth"
else
    if ! tokens | grep -q ^User; then
	echo "You must have a valid AFS token to do a backup (or be root)." > /dev/stderr
	exit 1
    fi
fi

# --------------
# Get volumes for backup
if echo "$VOLUMES" | grep -q ^users; then
    VOLUMES=`vos listvol ${AFSSERVER:-localhost} -quiet $LOCALAUTH | grep ^user | egrep -v '^root|readonly|\.backup|\.rescue' | sed 's@\ .*@@'`
elif echo "$VOLUMES" | grep -q ^public; then
    VOLUMES=`vos listvol ${AFSSERVER:-localhost} -quiet $LOCALAUTH | grep ^public | egrep -v '^root|readonly|\.backup|\.rescue' | sed 's@\ .*@@'`
elif echo "$VOLUMES" | grep -q ^common; then
    VOLUMES=`vos listvol ${AFSSERVER:-localhost} -quiet $LOCALAUTH | grep ^common | egrep -v '^root|readonly|\.backup|\.rescue' | sed 's@\ .*@@'`
else
    if [ -z "$VOLUMES" ]; then
	VOLUMES=`vos listvol ${AFSSERVER:-localhost} -quiet -localauth | grep '^[a-z]' | egrep -v '^root|^bogus|readonly|\.backup' | sed -e 's@ .*@@' | sort`
    fi
fi
VOLUMES=`echo $VOLUMES $EXTRA_VOLUMES`

do_backup

if [ -n "$MISSING_VOLUMES" ]; then
    echo "ERROR: Did not backup the volumes: $MISSING_VOLUMES." > /dev/stderr

    # Sleep for five minutes before trying again...
    echo -n "Sleeping for 5 minutes, before we try again... " > /dev/stderr
    sleep 300s
    echo "done." > /dev/stderr

    # Backup the missing volumes...
    VOLUMES=$MISSING_VOLUMES
    do_backup
else
    echo "Successfully backed up AFS volume(s)."
    exit 0
fi
