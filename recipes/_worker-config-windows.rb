#
# Cookbook Name:: scala-jenkins-infra
# Recipe:: _worker-config-windows
#
# Copyright 2014, Typesafe, Inc.
#
# All rights reserved - Do Not Redistribute
#

# XXX for the jenkins recipe: ensure_update_center_present! bombs without it (https://github.com/opscode-cookbooks/jenkins/issues/305)
ruby_block 'Enable ruby ssl on windows' do
  block do
    ENV[SSL_CERT_FILE] = 'c:\opscode\chef\embedded\ssl\certs\cacert.pem'
  end
  action :nothing
end

require "chef-vault"

jenkinsMaster = search(:node, 'name:jenkins-master').first

# Set the private key on the Jenkins executor
ruby_block 'set private key' do
  block do
    node.run_state[:jenkins_private_key] = ChefVault::Item.load("master", "scala-jenkins-keypair")['private_key']
    node.set['jenkins']['master']['endpoint'] = "http://#{jenkinsMaster.ipaddress}:#{jenkinsMaster.jenkins.master.port}"
    Chef::Log.warn("Master end point: #{jenkinsMaster.jenkins.master.endpoint} / computed: #{node['jenkins']['master']['endpoint']}")
  end
end

# TODO: can we use an IAM instance profile? not urgent, but shouldn't run PR validation on windows until we separate this out
{
  "/.s3credentials"                  => "s3credentials.erb"
}.each do |target, templ|
  template target do
    source templ
    sensitive true
    # user node['jenkins']['master']['user']
    # group node['jenkins']['master']['group']

    variables({
      :s3DownloadsPass => ChefVault::Item.load("worker-publish", "s3-downloads")['pass'],
      :s3DownloadsUser => ChefVault::Item.load("worker-publish", "s3-downloads")['user']
    })
  end
end

node["jenkinsHomes"].each do |jenkinsHome, workerConfig|
  # TODO: somehow, we can't wipe the workspace -- is it because the jenkins slave service somehow hangs on to a file?
  # As a workaround, store files on ephemeral storage so at least a reboot of the slave will give us a clean workspace. (On EBS right now.)
  # Maybe we should move to ssh for windows to avoid the issue of the service hanging on to files (also can't reinstall java because of that)

  # if you specify a user, must also specify a password!! by default, runs under the LocalSystem account (no password needed)
  # this is the only type of slave that will work on windows (the jnlp one does not launch automatically)
  jenkins_windows_slave workerConfig["workerName"] do
    group   "Administrators"
    tunnel  "#{jenkinsMaster.ipaddress}:" # specify tunnel that stays inside the VPC, needed to avoid going through the reverse proxy

    remote_fs   jenkinsHome
    labels      workerConfig["labels"]
    executors   workerConfig["executors"]

    environment((eval node["master"]["env"]).call(node).merge((eval workerConfig["env"]).call(node)))

    action [:create, :connect, :online] # TODO: are both connect and online needed?
  end
end