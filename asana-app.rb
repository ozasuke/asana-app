# プロジェクトフォルダへ、プロジェクトの状態を同期する
require 'bundler'
Bundler.require
PROJECT_FOLDER_ID = 509518388925871
EXCLUSION_PROJECT_IDS = [76407283370083, 510014371605748]
ACCESS_TOKEN = ENV['ASANA_ACCESS_TOKEN']

client = Asana::Client.new do |c|
  c.authentication :access_token, ACCESS_TOKEN
end

module Asana::Resources
  class Project
    def select_same_task(tasks)
      tasks.find{|t| id == t.notes.strip.to_i}
    end
  end

  class Task < Resource
    def add_project(project: required("project"), insert_after: nil, insert_before: nil, section: nil, options: {}, **data)
      with_params = data.merge(project: project, insert_after: insert_after, insert_before: insert_before, section: section).reject { |_,v| v.nil? || Array(v).empty? }
      client = Asana::Client.new do |c|
        c.authentication :access_token, ACCESS_TOKEN
      end
      client.post("/tasks/#{id}/addProject", body: with_params, options: options) && true
    end
  end
end

def have_to_expect?(project)
  EXCLUSION_PROJECT_IDS.include?(project.id) || 
    PROJECT_FOLDER_ID == project.id ||
    colored?(project)
end

def colored?(project)
  (![nil, 'none'].include?(project.color))
end

def oldest_due_on
  $tasks_in_project_folder.map(&:due_on).sort.first
end

def base_data(project, index: 0, due_on: oldest_due_on)
  num_str = "%02d" % (index + 1)
  {
    name: "#{num_str}.#{project.name}",
    notes: project.id.to_s,
    due_on: due_on,
    workspace: $workspace.id,
  }
end

def create_data(project, index: 0, pre_task: {})
  base_data(project, index: index, due_on: pre_task&.due_on)
end

def update_data(project, index: 0, pre_task: {}, due_on: nil)
  data = base_data(project, index: index, due_on: due_on || pre_task&.due_on)
  data.delete(:projects)
  data
end

$workspace = client.workspaces.find_all.first
target_project_folder = client.projects.find_by_id(PROJECT_FOLDER_ID)
$tasks_in_project_folder = client.tasks.find_all(project: target_project_folder.id).map{|t| client.tasks.find_by_id(t.id)}

all_projects = client.projects.find_all(workspace: $workspace.id, archived: false, per_page: 100)
all_projects = all_projects.map{|p| client.projects.find_by_id(p.id)}
target_projects = all_projects.reject{|p| have_to_expect?(p)}


# 現在activeなプロジェクトをプロジェクトフォルダへcopy or update
pre_task = nil
target_projects.each_with_index do |project, i|
  same_task = project.select_same_task($tasks_in_project_folder)
  if same_task.nil?
    changed_task = client.tasks.create(create_data(project, index: i, pre_task: pre_task))
  else
    changed_task = same_task.update(update_data(project, index: i, pre_task: pre_task, due_on: same_task.due_on))
  end
  changed_task.add_project(project: target_project_folder.id, insert_after: pre_task&.id)
  pre_task = changed_task
end

# プロジェクトフォルダ内のいらないtaskを削除

delete_tasks = $tasks_in_project_folder.reject do |task|
  project_ids = target_projects.map(&:id)
  notes_id = task.notes.strip.to_i
  project_ids.include?(notes_id)
end

delete_tasks.each do |task|
  task.delete
end
