#!/bin/bash
if [ "$(whoami)" != "root" ]; then
    echo "Sorry, you are not root."
    exit 1
fi

while [[ $# -gt 0 ]];  do
    key="$1"
    case $key in
	-e|--external-interface)
	EXT_IF="$2"
	shift # past argument
	;;
	-i|--internal-interface)
	INT_IF="$2"
	shift # past argument
	;;
	-o|--open-port)
	OPEN_PORT="$2"
	shift # past argument
	;;
	-c|--cmd)
	IPCMD="$2"
	shift # past argument
	;;
	-t|--trust)
	ALLOW_HOSTS="$2"
	shift # past argument
	;;
	-s|--status)
        SHOW_STATUS_ONLY=on
	shift # past argument
	;;
	--reset-only)
        RESET_ONLY=on
	shift # past argument
	;;

	*)
	# unknown option
	;;
    esac
    shift # past argument or value
done

if [ -z "$IPCMD" ] ; then
    IPCMD="iptables";
fi

## Check if iptalbe exists 
CHK_IPTABLES=$(which $IPCMD 2>/dev/null)
if [ -z "$CHK_IPTABLES" ]; then
    echo
    echo "$(basename $0): iptables program is not found."
    echo "	Please install the program first."
    echo
    exit 1
fi

if [ -n "$SHOW_STATUS_ONLY" ] ; then
    $IPCMD -S
    exit;
fi

initialize ()
{
    $IPCMD -P INPUT   ACCEPT
    $IPCMD -P OUTPUT  ACCEPT
    $IPCMD -P FORWARD ACCEPT
    $IPCMD -F
    $IPCMD -X
    $IPCMD -Z
}

if [ -n "$RESET_ONLY" ] ; then
    echo "# Reset only"
    initialize
    $IPCMD -S
    exit;
fi

if [ -z "$EXT_IF" ] ; then
    echo "External Interface should not be empty"
    exit;
fi

if [ -z "$INT_IF" ] ; then
    INT_IF=$EXT_IF;
fi


echo "## Paramters"
echo ""

echo "# External Interface:"
echo $EXT_IF 
echo "" 

echo "# Internal Interface:"
echo $INT_IF 
echo "" 

if [ "${OPEN_PORT}" ] ; then
    echo "# Open Ports:"
    for port in ${OPEN_PORT[@]} ; do
        echo $port 
    done
    echo ""
fi

echo "# Iptable command-line path:"
echo $IPCMD 
echo "" 

if [ "${ALLOW_HOSTS}" ] ; then
    echo "# Trust Hosts:"
    for allow_host in ${ALLOW_HOSTS[@]} ; do
        echo $allow_host 
    done
    echo ""
fi

echo "###"
echo "# Start to apply firewall"
echo "###"


## Library
netinfo ()
{
    IP=""
    MASK=""
    NET=""

    for NIC in "$@" ; do
        {
        IP=`ifconfig $NIC |grep 'inet addr' |awk '{print $2}'|sed -e "s/addr\://"`
        MASK=`ifconfig $NIC |grep 'inet addr' |awk '{print $4}'|sed -e "s/Mask\://"`
        IP1=`echo $IP |awk -F'.' '{print $1}'`
        if [ "$IP1" = "" ]; then
            echo ""
            echo "Warning: there is no IP found on $NIC."
            echo "Action is aborted."
            echo "Please make sure the interface is setup properly, then try again."
            echo ""
            exit 1
        else
        IP2=`echo $IP |awk -F'.' '{print $2}'`
        IP3=`echo $IP |awk -F'.' '{print $3}'`
        IP4=`echo $IP |awk -F'.' '{print $4}'`
        MASK1=`echo $MASK |awk -F'.' '{print $1}'`
        MASK2=`echo $MASK |awk -F'.' '{print $2}'`
        MASK3=`echo $MASK |awk -F'.' '{print $3}'`
        MASK4=`echo $MASK |awk -F'.' '{print $4}'`
        let NET1="$IP1 & $MASK1"
        let NET2="$IP2 & $MASK2"
        let NET3="$IP3 & $MASK3"
        let NET4="$IP4 & $MASK4"
        NET="$NET1.$NET2.$NET3.$NET4"
        fi
        }
    done
}

## default
initialize
HI="1025:65535"

## Outside
netinfo "$EXT_IF"
EXT_IP="$IP"
EXT_NET="$NET"/"$MASK"

echo ""
echo "## External IP"
echo $EXT_IP
echo "## External Net"
echo $EXT_NET
echo ""

## Inside 
netinfo "$INT_IF"
INT_IP="$IP"
INT_NET="$NET"/"$MASK"

echo "## Internal IP"
echo $INT_IP
echo "## Internal Net"
echo $INT_NET
echo ""



## Default drop all
$IPCMD -P INPUT DROP
$IPCMD -P FORWARD DROP

## Allow lo
$IPCMD -A INPUT -i lo -j ACCEPT
$IPCMD -A OUTPUT -o lo -j ACCEPT

## Allow internal
if [ "$INT_IF" != "$EXT_IF" ] ; then
   $IPCMD -A INPUT -i $INT_IF -j ACCEPT
   $IPCMD -A OUTPUT -o $INT_IF -j ACCEPT
   $IPCMD -A FORWARD -i $INT_IF -j ACCEPT
   $IPCMD -A FORWARD -o $INT_IF -j ACCEPT
fi

## Allow trust
if [ "${ALLOW_HOSTS}" ] ; then
    for allow_host in ${ALLOW_HOSTS[@]} ; do
	$IPCMD -A INPUT -p tcp -s $allow_host -j ACCEPT
    done
fi

###
# Defend ping-of-death
###
$IPCMD -N PING_OF_DEATH
$IPCMD -A PING_OF_DEATH -p icmp --icmp-type echo-request \
         -m hashlimit \
         --hashlimit 1/s \
         --hashlimit-burst 10 \
         --hashlimit-htable-expire 300000 \
         --hashlimit-mode srcip \
         --hashlimit-name t_PING_OF_DEATH \
         -j RETURN

$IPCMD -A PING_OF_DEATH -j LOG --log-prefix "ping_of_death_attack: "
$IPCMD -A PING_OF_DEATH -j DROP
$IPCMD -A INPUT -p icmp --icmp-type echo-request -j PING_OF_DEATH

###
# Defend sync flood
###
$IPCMD -N synfoold
$IPCMD -A synfoold -p tcp --syn -m limit --limit 10/s -j RETURN
$IPCMD -A synfoold -p tcp -j REJECT --reject-with tcp-reset
$IPCMD -A INPUT -p tcp -m state --state NEW -j synfoold

###
# Defend malicious scan
###
$IPCMD -A INPUT -i $EXT_IF -p tcp --tcp-flags ALL FIN,URG,PSH -j DROP
$IPCMD -A INPUT -i $EXT_IF -p tcp --tcp-flags ALL ALL -j DROP
$IPCMD -A INPUT -i $EXT_IF -p tcp --tcp-flags ALL SYN,RST,ACK,FIN,URG -j DROP
$IPCMD -A INPUT -i $EXT_IF -p tcp --tcp-flags ALL NONE -j DROP
$IPCMD -A INPUT -i $EXT_IF -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
$IPCMD -A INPUT -i $EXT_IF -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
$IPCMD -A INPUT -i $EXT_IF -p tcp --tcp-flags SYN,ACK,FIN,RST RST -m limit --limit 6/m -j ACCEPT

# tcp_packets
$IPCMD -N tcp_packets
$IPCMD -A tcp_packets -p TCP --tcp-flags ALL FIN,URG,PSH -j LOG --log-prefix "been scanned:"
$IPCMD -A tcp_packets -p TCP --tcp-flags ALL ALL -j LOG --log-prefix "been scanned:"
$IPCMD -A tcp_packets -p TCP --tcp-flags ALL SYN,RST,ACK,FIN,URG -j LOG --log-prefix "been scanned:"
$IPCMD -A tcp_packets -p TCP --tcp-flags ALL NONE -j LOG --log-prefix "been scanned:"
$IPCMD -A tcp_packets -p TCP --tcp-flags SYN,RST SYN,RST -j LOG --log-prefix "been scanned:"
$IPCMD -A tcp_packets -p TCP --tcp-flags SYN,FIN SYN,FIN -j LOG --log-prefix "been scanned:"
$IPCMD -A tcp_packets -p TCP --tcp-flags ALL FIN,URG,PSH -j DROP
$IPCMD -A tcp_packets -p TCP --tcp-flags ALL ALL -j DROP
$IPCMD -A tcp_packets -p TCP --tcp-flags ALL SYN,RST,ACK,FIN,URG -j DROP
$IPCMD -A tcp_packets -p TCP --tcp-flags ALL NONE -j DROP
$IPCMD -A tcp_packets -p TCP --tcp-flags SYN,RST SYN,RST -j DROP
$IPCMD -A tcp_packets -p TCP --tcp-flags SYN,FIN SYN,FIN -j DROP
$IPCMD -A FORWARD -p tcp -j tcp_packets

## Allow tcp packet for open port
$IPCMD -N allowed
$IPCMD -A allowed -p TCP --syn -j ACCEPT
$IPCMD -A allowed -p TCP -m state --state ESTABLISHED,RELATED -j ACCEPT
$IPCMD -A allowed -p TCP -j DROP
$IPCMD -A tcp_packets -p TCP -s 0/0 --dport 1024:65535 -j allowed
for PORT in $OPEN_PORT; do
    $IPCMD -A tcp_packets -p TCP -s 0/0 --dport $PORT -j allowed
done

## Drop illegal connection
$IPCMD -A INPUT -i $EXT_IF -m state --state RELATED,ESTABLISHED -j ACCEPT 
$IPCMD -A FORWARD -i $EXT_IF -m state --state NEW,INVALID -j DROP 
$IPCMD -A OUTPUT -m state --state INVALID -j DROP

###
# Enalbe internal routing
###
if [ "$INT_IF" != "$EXT_IF" ] ; then
   $IPCMD -t nat -P PREROUTING   ACCEPT
   $IPCMD -t nat -P POSTROUTING  ACCEPT
   $IPCMD -t nat -A POSTROUTING -s $INT_NET -j SNAT --to-source $EXT_IP
   $IPCMD -t nat -A POSTROUTING -o $EXT_IF -s $INT_NET -j MASQUERADE

   ## Docker
   $IPCMD -N DOCKER
   $IPCMD -N DOCKER-ISOLATION
   $IPCMD -N DOCKER-USER
   $IPCMD -A FORWARD -j DOCKER-USER
   $IPCMD -A FORWARD -j DOCKER-ISOLATION
   $IPCMD -A FORWARD -o $INT_NET -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
   $IPCMD -A FORWARD -o $INT_NET -j DOCKER
   $IPCMD -A FORWARD -i $INT_NET ! -o $INT_NET -j ACCEPT
   $IPCMD -A FORWARD -i $INT_NET -o $INT_NET -j ACCEPT
   $IPCMD -A DOCKER-ISOLATION -j RETURN
   $IPCMD -A DOCKER-USER -j RETURN
fi

## Wrap packet
$IPCMD -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
$IPCMD -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
$IPCMD -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

## Enable OPEN_PORT
for PORT in $OPEN_PORT; do
    $IPCMD -A INPUT -i $EXT_IF -p tcp --dport $PORT -j ACCEPT
    $IPCMD -A INPUT -i $EXT_IF -p udp --dport $PORT -j ACCEPT
    $IPCMD -A INPUT -p tcp --sport $HI -d $EXT_IP --dport $PORT -j ACCEPT
    $IPCMD -A INPUT -p udp --sport $HI -d $EXT_IP --dport $PORT -j ACCEPT
    $IPCMD -A OUTPUT -o $EXT_IF -p tcp --dport $PORT -j ACCEPT
    $IPCMD -A OUTPUT -o $EXT_IF -p udp --dport $PORT -j ACCEPT
    $IPCMD -A OUTPUT -p tcp --sport $HI -d $EXT_IP --dport $PORT -j ACCEPT
    $IPCMD -A OUTPUT -p udp --sport $HI -d $EXT_IP --dport $PORT -j ACCEPT
    $IPCMD -A FORWARD -i $EXT_IF -p tcp --dport $PORT -j ACCEPT
    $IPCMD -A FORWARD -i $EXT_IF -p udp --dport $PORT -j ACCEPT
    $IPCMD -A FORWARD -p tcp --sport $HI -d $EXT_IP --dport $PORT -j ACCEPT
    $IPCMD -A FORWARD -p udp --sport $HI -d $EXT_IP --dport $PORT -j ACCEPT
done

$IPCMD -A PREROUTING -t mangle -p tcp --dport 80 -j TOS --set-tos 16
$IPCMD -A PREROUTING -t mangle -p tcp --dport 443 -j TOS --set-tos 16
$IPCMD -A PREROUTING -t mangle -p tcp --dport 53 -j TOS --set-tos 8
$IPCMD -A PREROUTING -t mangle -p udp --dport 53 -j TOS --set-tos 16

## List rules
echo "## Check All Rules"
$IPCMD -S
exit;
