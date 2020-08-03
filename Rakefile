#!/usr/bin/env rake
# Add your own tasks in files placed in lib/tasks ending in .rake,
# for example lib/tasks/capistrano.rake, and they will automatically be available to Rake.

require File.expand_path('../config/application', __FILE__)

Rubyci::Application.load_tasks

task copy_signature_files: :environment do
  require 'rbs_rails'

  to = Rails.root.join('sig/rbs_rails/')
  to.mkpath unless to.exist?
  RbsRails.copy_signatures(to: to)
end

task generate_rbs_for_model: :environment do
  require 'rbs_rails'

  out_dir = Rails.root / 'sig'
  out_dir.mkdir unless out_dir.exist?

  Rails.application.eager_load!

  ActiveRecord::Base.descendants.each do |klass|
    next if klass.abstract_class?

    path = out_dir / "app/models/#{klass.name.underscore}.rbs"
    FileUtils.mkdir_p(path.dirname)

    sig = RbsRails::ActiveRecord.class_to_rbs(klass)
    path.write sig
  end
end

task generate_rbs_for_path_helpers: :environment do
  require 'rbs_rails'
  out_path = Rails.root.join 'sig/path_helpers.rbs'
  rbs = RbsRails::PathHelpers.generate
  out_path.write rbs
end