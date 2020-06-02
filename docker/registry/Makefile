
default: network volumes
	docker-compose up -d

network:
	docker network inspect dbnet >/dev/null 2>&1 || \
		docker network create --subnet 172.21.0.0/16 --gateway 172.21.0.1 --opt com.docker.network.bridge.enable_ip_masquerade=true --opt com.docker.network.bridge.name=dbnet dbnet

volumes:
	docker volume create redis
	docker volume create registry
	docker volume create postgres
