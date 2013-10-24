# Get our Database settings
database = data_bag_item("secrets", "postgres")

# Get our secrets
secrets = data_bag_item("secrets", "pypi")

# Make sure Nginx is installed
include_recipe "nginx"

# Make sure supervisor is available to us
include_recipe "supervisor"

# Make sure Node.js is installed
include_recipe "nodejs::install_from_binary"

# Make sure lessc is installed
execute "install_lessc" do
  command "npm install -g less"
end

environ = {
  "LANG" => "en_US.UTF8",
  "WAREHOUSE_CONF" => "/opt/warehouse/etc/config.yml",
  "SENTRY_DSN" => secrets["sentry"]["dsn"],
}

apt_repository "pypy" do
    uri "http://ppa.launchpad.net/pypy/ppa/ubuntu"
    distribution node['lsb']['codename']
    components ["main"]
    keyserver "keyserver.ubuntu.com"
    key "2862D0785AFACD8C65B23DB0251104D968854915"
end

apt_repository "warehouse" do
    uri "http://f30946d9bf6d8f30a9b7-8a1b7b6e827d25e65cef20ed702fa327.r51.cf5.rackcdn.com/"
    distribution node['lsb']['codename']
    components ["main"]
    key "http://f30946d9bf6d8f30a9b7-8a1b7b6e827d25e65cef20ed702fa327.r51.cf5.rackcdn.com/pubkey.gpg"
end

group "warehouse" do
  system true
end

user "warehouse" do
  comment "Warehouse Service"
  gid "warehouse"
  system true
  shell '/bin/false'
  home "/opt/warehouse"
end

package "warehouse" do
  action :upgrade

  notifies :run, "execute[fixup /opt/warehouse owner]", :immediately
  notifies :run, "execute[collectstatic]"
  notifies :restart, "supervisor_service[warehouse]"
end

# TODO: Figure out how to do this in warehouse packaging
execute "fixup /opt/warehouse owner" do
  command "chown -Rf warehouse:warehouse /opt/warehouse"
  action :nothing
end

# TODO: Can we move this into packaging?
execute "collectstatic" do
  command "/opt/warehouse/bin/warehouse -c /opt/warehouse/etc/config.yml collectstatic"
  environment environ
  user "warehouse"
  group "warehouse"
  action :nothing
end

# TODO: Can we move this into packaging?
gunicorn_config "/opt/warehouse/etc/gunicorn.config.py" do
  owner "warehouse"
  group "warehouse"

  listen "unix:/opt/warehouse/var/warehouse.sock"

  action :create
  notifies :restart, "supervisor_service[warehouse]"
end

file "/opt/warehouse/etc/config.yml" do
  owner "warehouse"
  group "warehouse"
  mode "0750"
  backup false

  content ({
    "debug" => false,
    "site" => {
      "name" => "Python Package Index (Preview)",
    },
    "database" => {
      "url" => database["pypi"]["url"],
    },
    "redis" => {
      "url" => "redis://localhost:6379/0",
    },
    "assets" => {
      "directory" => "/opt/warehouse/var/www/static"
    },
    "urls" => {
      "documentation" => "http://pythonhosted.org/",
    },
    "paths" => {
      "packages" => "/data/packages",
      "documentation" => "/data/packagedocs",
    },
    "cache" => {
      "browser" => {
        "simple" => 900,
        "packages" => 900,
        "project_detail" => 60,
      },
      "varnish" => {
        "simple" => 86400,
        "packages" => 86400,
        "project_detail" => 60,
      },
    },
  }.to_yaml)

  notifies :restart, "supervisor_service[warehouse]"
end

# TODO: Move this into packaging
python_pip "gunicorn" do
  virtualenv "/opt/warehouse"
  action :upgrade
  notifies :restart, "supervisor_service[warehouse]"
end

supervisor_service "warehouse" do
  command "/opt/warehouse/bin/gunicorn -c /opt/warehouse/etc/gunicorn.config.py warehouse.wsgi"
  process_name "warehouse"
  directory "/opt/warehouse"
  environment environ
  user "warehouse"
  action :enable
end

template "#{node['nginx']['dir']}/sites-available/warehouse.conf" do
  owner "root"
  group "root"
  mode "0755"
  backup false

  source "nginx-warehouse.conf.erb"

  variables ({
    :domains => node["warehouse"]["domains"],
    :sock => "/opt/warehouse/var/warehouse.sock",
    :name => "warehouse",
    :static_root => "/opt/warehouse/var/www",
  })

  notifies :reload, "service[nginx]"
end

nginx_site "warehouse.conf" do
  enable true
end
