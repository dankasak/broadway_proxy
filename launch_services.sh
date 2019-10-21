perl broadway_proxy.pl &
sleep 1

perl auth_service.pl &
sleep 1

perl user_app_service.pl &
sleep 1

echo "Services started ..."

