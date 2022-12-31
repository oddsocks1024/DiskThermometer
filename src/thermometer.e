OPT PREPROCESS, OSVERSION=37

/*
    Program:     Thermometer!
    Version:     0.3
    Author:      Ian Chapman
    Description: Display the temperature for modern SCSI disks.

    This code was written rather quickly as most of it was ripped from Q-Device
    then bolted together. It could probably be improved.
*/

MODULE  'exec/ports',
        'exec/io',
        'exec/memory',
        'amigalib/io',
        'devices/scsidisk',
        'dos/var',
        ->'miami/netinclude/pragmas/socket',
        ->'amitcp/sys/ioctl',
        ->'amitcp/sys/socket',
        ->'amitcp/sys/types',
        ->'amitcp/sys/time',
        ->'amitcp/netdb',
        ->'amitcp/netinet/in',
        '*/q-device/scsi/headers',
        '*/q-device/scsi/params',
        '*/q-device/scsi/opcodes'

CONST BUFFSIZE=255

ENUM NORMAL, ERR_BADARGS, ERR_NOMEM, ERR_MP, ERR_IOR, ERR_DEVICE ->, ERR_NOBSD, ERR_NOCONNECT, ERR_NOSOCK

RAISE ERR_NOMEM IF NewM()=NIL

DEF devicename[255]:STRING,
    unit=NIL,
    verbose=NIL,
    found=NIL

PROC main() HANDLE
DEF myargs:PTR TO LONG,
    rdargs

myargs:=[NIL, NIL, NIL, NIL]

IF rdargs:=ReadArgs('DEVICE/A,UNIT/N,VERBOSE/S', myargs, NIL)
    StrCopy(devicename, myargs[0])
    unit:=Long(myargs[1])
    verbose:=myargs[2]
    FreeArgs(rdargs)
ELSE
    Raise(ERR_BADARGS)
ENDIF

->Reset Environment Variables

SetVar('THERM_CUR_C', '', 0, LV_VAR OR GVF_GLOBAL_ONLY)
SetVar('THERM_REF_C', '', 0, LV_VAR OR GVF_GLOBAL_ONLY)
SetVar('THERM_MRR_C', '', 0, LV_VAR OR GVF_GLOBAL_ONLY)
SetVar('THERM_CUR_F', '', 0, LV_VAR OR GVF_GLOBAL_ONLY)
SetVar('THERM_REF_F', '', 0, LV_VAR OR GVF_GLOBAL_ONLY)
SetVar('THERM_MRR_F', '', 0, LV_VAR OR GVF_GLOBAL_ONLY)

IF scan_templog() = 0
    IF scan_ielog() = 0
        scan_ibmtemplog()
    ENDIF
ENDIF

EXCEPT DO
    SELECT exception
        CASE NORMAL
            IF (found = 0)
                IF (verbose <> FALSE) THEN PrintF('No Temperature Sensor Found\n')
            ENDIF
        CASE ERR_BADARGS
            PrintF('Thermometer v0.3 by Ian Chapman\n')
            PrintF('A program for reading hard drive temperatures\n\n')
            PrintF('Parameters: DEVICE/A,UNIT/N,VERBOSE/S\n')
            PrintF('Example: thermometer cybppc.device 0\n')
        CASE ERR_NOMEM
            PrintF('Error: Unable to allocate memory\n')
        DEFAULT
            PrintF('Error: Unknown exception (\d). Please report to author.\n', exception)
    ENDSELECT

ENDPROC exception


/*
** Procedure for simply sending the SCSI command to the scsi device driver and
** writing the return data into the buffer for processing by the handler
** procedures
*/

PROC scsiquery(device:PTR TO CHAR, unit, cmd:PTR TO cdb12, size, buffer) HANDLE
DEF myport=NIL:PTR TO mp, ioreq=NIL:PTR TO iostd, scsiio:scsicmd, error=-1, status

    IF (myport:=CreateMsgPort())=NIL THEN Raise(ERR_MP)
    IF (ioreq:=createStdIO(myport))=NIL THEN Raise(ERR_IOR)
    IF (error:=OpenDevice(device, unit, ioreq, 0)) <> NIL THEN Raise(ERR_DEVICE)

    scsiio.data:=buffer
    scsiio.length:=BUFFSIZE
    scsiio.command:=cmd
    scsiio.cmdlength:=size
    scsiio.flags:=SCSIF_READ -> OR SCSIF_AUTOSENSE
    scsiio.senseactual:=0
    ioreq.command:=HD_SCSICMD
    ioreq.data:=scsiio
    ioreq.length:=SIZEOF scsicmd
    DoIO(ioreq)
    status:=ioreq.error

    SELECT status
        CASE HFERR_SELFUNIT
            PrintF('\s[\d]: <self issuing command error>\n', device, unit)
        CASE HFERR_DMA
            PrintF('\s[\d]: <DMA Failure>\n', device, unit)
        CASE HFERR_PHASE
            PrintF('\s[\d]: <illegal scsi phase>\n', device, unit)
        CASE HFERR_PARITY
            PrintF('\s[\d]: <parity error>\n', device, unit)
        CASE HFERR_SELTIMEOUT
            PrintF('\s[\d]: <device timed out>\n', device, unit)
    ENDSELECT

    EXCEPT DO
        IF error=NIL
            IF  CheckIO(ioreq)<>NIL
                AbortIO(ioreq)
                WaitIO(ioreq)
            ENDIF
        ENDIF

    CloseDevice(ioreq)
    IF ioreq <> NIL THEN deleteStdIO(ioreq)
    IF myport <> NIL THEN DeleteMsgPort(myport)

    SELECT exception
        CASE ERR_MP
            PrintF('Error: Unable to create message port\n')
        CASE ERR_IOR
            PrintF('Error: Unable to create IORequest\n')
        CASE ERR_DEVICE
            PrintF('\s[\d]: <no device found>\n', device, unit)
    ENDSELECT

ENDPROC (scsiio.status AND %00111110), exception


/*
** Check for a Temperature Log
*/
PROC scan_templog() 
DEF buffer,
    returncode,
    returnexcept,
    pagesize,
    buildstr[4]:STRING

buffer:=NewM(BUFFSIZE, MEMF_CLEAR)

IF (verbose <> FALSE) THEN PrintF('Scanning for STANDARD temperature log\n')

returncode, returnexcept := scsiquery(devicename, unit, [SCSI_LOG_SENSE, 0, P_LOG_TEMP, 0, 0, 0, 0, 0, BUFFSIZE, 0]:cdb10, SIZEOF cdb10, buffer)

IF (returnexcept = 0)
    IF (returncode <> 0)
        IF (verbose <> FALSE) THEN PrintF('    No STANDARD temperature log found\n')
    ELSE
        IF (verbose <> FALSE) THEN PrintF('    STANDARD temperature log found\n')
        pagesize := Int(buffer+2)
        IF (pagesize > 9)
            PrintF('Current Temperature: \dC (\dF)\n', Char(buffer+9), ctof(Char(buffer+9)))
            StringF(buildstr, '\d', Char(buffer+9))
            SetVar('THERM_CUR_C', buildstr, -1, LV_VAR OR GVF_GLOBAL_ONLY)
            StringF(buildstr, '\d', ctof(Char(buffer+9)))
            SetVar('THERM_CUR_F', buildstr, -1, LV_VAR OR GVF_GLOBAL_ONLY)
        ENDIF

        IF (pagesize > 16)
            PrintF('Reference Temperature: \dC (\dF)\n', Char(buffer+15), ctof(Char(buffer+15)))
            StringF(buildstr, '\d', Char(buffer+15))
            SetVar('THERM_REF_C', buildstr, -1, LV_VAR OR GVF_GLOBAL_ONLY)
            StringF(buildstr, '\d', ctof(Char(buffer+15)))
            SetVar('THERM_REF_F', buildstr, -1, LV_VAR OR GVF_GLOBAL_ONLY)
        ENDIF
        found:=1
    ENDIF
ENDIF

ENDPROC returnexcept


/*
** Check for Informational Exceptions log
*/
PROC scan_ielog()
DEF buffer,
    returncode,
    returnexcept,
    pagesize,
    buildstr[4]:STRING

buffer:=NewM(BUFFSIZE, MEMF_CLEAR)

IF (verbose <> FALSE) THEN PrintF('Scanning for Informational Exceptions\n')

returncode, returnexcept := scsiquery(devicename, unit, [SCSI_LOG_SENSE, 0, P_LOG_IE, 0, 0, 0, 0, 0, BUFFSIZE, 0]:cdb10, SIZEOF cdb10, buffer)

IF (returnexcept = 0)
    IF (returncode <> 0)
        IF (verbose <> FALSE) THEN PrintF('    No Informational Exceptions found\n')
    ELSE
        IF (verbose <> FALSE) THEN PrintF('    Informational Exceptions found\n')
        pagesize := Int(buffer+2)
        IF Int(buffer+4) = 0
            IF (pagesize > 10)
                found:=1
                PrintF('Most Recent Temperature Reading: \dC (\dF)\n', Char(buffer+10), ctof(Char(buffer+10)))
                StringF(buildstr, '\d', Char(buffer+10))
                SetVar('THERM_MRR_C', buildstr, -1, LV_VAR OR GVF_GLOBAL_ONLY)
                StringF(buildstr, '\d', ctof(Char(buffer+10)))
                SetVar('THERM_MRR_F', buildstr, -1, LV_VAR OR GVF_GLOBAL_ONLY)

            ELSE
                IF (verbose <> FALSE) THEN PrintF('    No Temperature found in Informational Exceptions\n')
            ENDIF
        ELSE
            IF (verbose <> FALSE) THEN PrintF('    No Temperature found in Informational Exceptions\n')
        ENDIF
    ENDIF
ENDIF

ENDPROC


/*
** Check for IBM Temperature Log
*/
PROC scan_ibmtemplog() 
DEF buffer,
    returncode,
    returnexcept,
    pagesize,
    buildstr[4]:STRING

buffer:=NewM(BUFFSIZE, MEMF_CLEAR)

IF (verbose <> FALSE) THEN PrintF('Scanning for IBM Temperature log\n')

returncode, returnexcept := scsiquery(devicename, unit, [SCSI_LOG_SENSE, 0, P_LOG_IBMTEMP, 0, 0, 0, 0, 0, BUFFSIZE, 0]:cdb10, SIZEOF cdb10, buffer)

IF (returnexcept = 0)
    IF (returncode <> 0)
        IF (verbose <> FALSE) THEN PrintF('    No IBM temperature log found\n')
    ELSE
        IF (verbose <> FALSE) THEN PrintF('    IBM Temperature log found\n')
        pagesize := Int(buffer+2)        
        PrintF('Current Temperature: \dC (\dF)\n', Char(buffer+9), ctof(Char(buffer+9)))
        StringF(buildstr, '\d', Char(buffer+9))
        SetVar('THERM_CUR_C', buildstr, -1, LV_VAR OR GVF_GLOBAL_ONLY)
        StringF(buildstr, '\d', ctof(Char(buffer+9)))
        SetVar('THERM_CUR_F', buildstr, -1, LV_VAR OR GVF_GLOBAL_ONLY)
        IF (pagesize > 16)
            PrintF('Reference Temperature: \dC (\dF)\n', Char(buffer+15), ctof(Char(buffer+15)))
            StringF(buildstr, '\d', Char(buffer+15))
            SetVar('THERM_REF_C', buildstr, -1, LV_VAR OR GVF_GLOBAL_ONLY)
            StringF(buildstr, '\d', ctof(Char(buffer+15)))
            SetVar('THERM_REF_F', buildstr, -1, LV_VAR OR GVF_GLOBAL_ONLY)
        ENDIF
        found:=1
    ENDIF
ENDIF

ENDPROC returnexcept


/*
** Convert Celsius to Fahrenheit
*/
PROC ctof(c)
DEF f

IF (c=0)
    f:=32
ELSE
    f:=( (c * 9) / 5) + 32
ENDIF

ENDPROC f



/* CODE BELOW THIS LINE SHOULD BE COMMENTED OUT, FOR TESTING PURPOSES ONLY */

/*
PROC netquery(device:PTR TO CHAR, unit, cmd:PTR TO cdb12, size, buffer) HANDLE
DEF sock, sain:PTR TO sockaddr_in, received=0, returncode=0, hst:PTR TO hostent,
    address:in_addr, saou:sockaddr_in, tv:timeval, readfds:fd_set, host[255]:STRING

    StrCopy(host, 'nimo')

    IF (socketbase:=OpenLibrary('bsdsocket.library', NIL)) = NIL THEN Raise(ERR_NOBSD)
    sain:=NewM(SIZEOF sockaddr_in, MEMF_PUBLIC OR MEMF_CLEAR)
    IF (host[0] > 47) AND (host[0] < 58)
        address.addr:=Inet_addr(host)
        IF address.addr = INADDR_NONE THEN Raise(ERR_NOCONNECT)
        IF (hst:=Gethostbyaddr(address, SIZEOF in_addr, AF_INET)) = NIL THEN Raise(ERR_NOCONNECT)
    ELSE
        IF (hst:=Gethostbyname(host)) = NIL THEN Raise(ERR_NOCONNECT)
        address:=hst.addr_list[0]
    ENDIF

    sain.family:=AF_INET
    sain.addr.addr:=address.addr
    sain.port:=8000
    IF (sock:=Socket(AF_INET, SOCK_DGRAM, 0)) = -1 THEN Raise(ERR_NOSOCK)
    Sendto(sock, cmd, size, 0, sain, SIZEOF sockaddr_in)

    fd_zero(readfds)
    fd_set(sock, readfds)

    -> Some commands take a long time to complete, so increase the timeout value
    IF cmd.opcode = SCSI_SEND_DIAGNOSTIC
        tv.sec:=19
        tv.usec:=5
    ELSEIF cmd.opcode = SCSI_CD_START_STOP_UNIT
        tv.sec:=10
        tv.usec:=5
    ELSEIF cmd.opcode = SCSI_DA_START_STOP_UNIT
        tv.sec:=10
        tv.usec:=5
    ELSE
        tv.sec:=1
        tv.usec:=5
    ENDIF

    IF WaitSelect(sock+1, readfds, NIL, NIL, tv, 0) > 0
        IF fd_isset(sock, readfds)
            IF ((received:=Recvfrom(sock, buffer, BUFFSIZE, 0, saou, SIZEOF sockaddr_in)) < 255)
                returncode:=Char(buffer)
            ENDIF
        ELSE
            Raise(ERR_NOCONNECT)
        ENDIF
    ELSE
        Raise(ERR_NOCONNECT)
    ENDIF

    EXCEPT DO
        IF sock <> -1 THEN CloseSocket(sock)
        IF (socketbase) THEN CloseLibrary(socketbase)
        SELECT exception
            CASE ERR_NOBSD
             ->   outlist('\ebError:\en', 'Unable to open bsdsocket.library')
            CASE ERR_NOSOCK
             ->   outlist('\ebError:\en', 'Unable to create socket')
            CASE ERR_NOCONNECT
             ->   outlist_d('<no device> (or unable to connect)', device, unit)
        ENDSELECT

ENDPROC returncode, exception

*/

version:
CHAR '$VER: Thermometer v0.3 by Ian Chapman',0


