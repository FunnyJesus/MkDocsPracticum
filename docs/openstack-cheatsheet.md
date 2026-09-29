# OpenStack: шпаргалка

Самые частые команды `openstack` CLI.

> Теория, Horizon и сценарии — [OpenStack](openstack.md).

## Топ-20

| # | Категория | Команда | Что делает |
|---|---|---|---|
| 1 | доступ | `export OS_CLOUD=lab` / `source project-openrc.sh` | выбрать облако из clouds.yaml / загрузить RC-файл |
| 2 | доступ | `openstack token issue` | проверить, что аутентификация работает |
| 3 | обзор | `openstack limits show --absolute` | сколько квоты использовано |
| 4 | обзор | `openstack flavor list` / `openstack image list` | размеры VM / образы |
| 5 | сеть | `openstack network list --external` | внешние сети (для роутера и floating IP) |
| 6 | сеть | `openstack network create app-net` | создать сеть |
| 7 | сеть | `openstack subnet create app-subnet --network app-net --subnet-range 10.10.0.0/24` | создать подсеть |
| 8 | сеть | `openstack router create r1 && openstack router set r1 --external-gateway public && openstack router add subnet r1 app-subnet` | роутер с выходом в интернет |
| 9 | firewall | `openstack security group rule create web-sg --protocol tcp --dst-port 22 --remote-ip <мой-ip>/32` | разрешить SSH |
| 10 | ключи | `openstack keypair create --public-key ~/.ssh/id_ed25519.pub mykey` | загрузить SSH-ключ |
| 11 | VM | `openstack server create web-1 --flavor m1.small --image "Ubuntu 24.04" --network app-net --key-name mykey --security-group web-sg --user-data cloud-init.yaml --wait` | создать VM |
| 12 | VM | `openstack server list -f value -c Name -c Status -c Networks` | список VM для скриптов |
| 13 | VM | `openstack server show web-1 -c status -c addresses -c fault` | статус, адреса, ошибка |
| 14 | IP | `openstack floating ip create public` | выделить публичный адрес |
| 15 | IP | `openstack server add floating ip web-1 <ip>` | привязать адрес к VM |
| 16 | отладка | `openstack console log show web-1 --lines 50` | лог загрузки (cloud-init) без SSH |
| 17 | отладка | `openstack console url show web-1` | ссылка на VNC-консоль |
| 18 | диски | `openstack volume create --size 20 data-1 && openstack server add volume web-1 data-1` | создать и подключить диск |
| 19 | снапшот | `openstack server image create --name web-1-snap --wait web-1` | образ из VM |
| 20 | удаление | `openstack server delete web-1 --wait` | удалить VM |

## Формат вывода

```bash
-f table | json | yaml | value | csv     # формат
-c Name -c Status                        # только нужные колонки
--long                                   # больше колонок в list
--debug                                  # HTTP-запросы к API (отладка ошибок)
```

## Минимальный clouds.yaml

```yaml
# ~/.config/openstack/clouds.yaml
clouds:
  lab:
    auth:
      auth_url: https://keystone.example.com:5000/v3
      username: alex
      project_name: devops-lab
      user_domain_name: Default
      project_domain_name: Default
    region_name: RegionOne
    identity_api_version: 3
# пароль — в ~/.config/openstack/secure.yaml (clouds.lab.auth.password)
```

## Первое, что проверить

| Проблема | Команда |
|---|---|
| VM в ERROR | `openstack server show <vm> -c fault` |
| Не создаётся — квота | `openstack limits show --absolute` |
| Нет доступа снаружи | `openstack security group rule list <sg>`, `openstack router show <router> -c external_gateway_info`, `openstack server show <vm> -c addresses` |
| cloud-init | `openstack console log show <vm> | grep -i cloud-init` |
| Не удаляется сеть | `openstack port list --network <net>` |
