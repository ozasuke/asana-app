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
    def select_same_section(sections, client)
      sections.find do |sec|
        id == sec.notes.strip.to_i
      end
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

    def subtasks(client, per_page: 20, options: {})
      params = { limit: per_page }.reject { |_,v| v.nil? || Array(v).empty? }
      Collection.new(parse(client.get("/tasks/#{id}/subtasks", params: params, options: options)), type: self.class, client: client)
    end
  end

  class Section < Resource
    def insert_in_project(project: required("project"), before_section: nil, after_section: nil, options: {}, **data)
      with_params = data.merge(before_section: before_section, after_section: after_section).reject { |_,v| v.nil? || Array(v).empty? }
      client = Asana::Client.new do |c|
        c.authentication :access_token, ACCESS_TOKEN
      end
      client.post("/projects/#{project}/sections/insert", body: with_params, options: options) && true
    end
  end
end

def have_to_expect?(project)
  EXCLUSION_PROJECT_IDS.include?(project.id) || 
    PROJECT_FOLDER_ID == project.id ||
    ng_colored?(project)
end

def ng_colored?(project)
  ['dark-brown', 'light-purple', 'light-warm-gray', nil, 'none', 'light-orange'].include?(project.color)
end

def oldest_due_on
  nil
  # $sections_in_project_folder.map(&:due_on).sort.first
end

def base_data(project, index: 0, due_on: oldest_due_on)
  num_str = "%02d" % (index + 1)
  {
    name: "#{num_str}.#{project.name}:",
    notes: project.id.to_s,
    # due_on: due_on,
    workspace: $workspace.id,
  }
end

def create_data(project, index: 0, pre_task: {})
  base_data(project, index: index)
end

def update_data(project, index: 0, pre_task: {}, due_on: nil)
  data = base_data(project, index: index)
  data.delete(:projects)
  data
end

def get_sections_in_project(client, project_id: )
  client.get("/projects/#{project_id}/sections").body['data']
end

def add_tasks_sections_in_this_project(section, project, client, target_project_folder)
  sections = get_sections_in_project(client, project_id: project.id)
  pre_task = nil
  sections.each do |real_section|
    same_task = $tasks_in_project_folder.find{|task| real_section['id'] == task.notes.to_s.strip.to_i }
    if same_task.nil?
      changed_task = client.tasks.create(name: real_section['name'].chop, notes: real_section['id'].to_s, workspace: $workspace.id)
      opts = pre_task.nil? ? {section: section.id} : {insert_after: pre_task.id}
      changed_task.add_project({project: target_project_folder.id}.merge(opts))
      p "#{changed_task.name}は新しいsectionだったので新しくtask追加"
    else
      changed_task = same_task.update(name: real_section['name'].chop, notes: real_section['id'].to_s, workspace: $workspace.id)
      p "#{changed_task.name}はすでにtaskにあったのでupdate"
    end
    pre_task = changed_task
  end
  delete_tasks = $tasks_in_project_folder_with_sections.select{|task| section.id == task.memberships.first&.[]('section')&.[]('id') }.reject do |task|
    return true  if task.name.end_with?(':')
    task = task.refresh
    section_ids = sections.map{|section| section['id'] }
    notes_id = task.notes.to_s.strip.to_i
    section_ids.include?(notes_id)
  end

  delete_tasks.each do |task|
    p "#{task.name}はいらないsubtaskなので削除"
    task.delete
  end

end

$workspace = client.workspaces.find_all.first
target_project_folder = client.projects.find_by_id(PROJECT_FOLDER_ID)
opts = {fields: ['id', 'name', 'notes', 'color']}
$sections_in_project_folder = client.sections.find_by_project(project: target_project_folder.id, options: opts)
$sections_in_project_folder_with_note = $sections_in_project_folder.map{|sec| client.tasks.find_by_id(sec.id, options: {fields: ['notes']})}
$tasks_in_project_folder = client.tasks.find_all(project: target_project_folder.id, options: opts)
$tasks_in_project_folder_with_sections = client.tasks.find_all(project: target_project_folder.id, options: {expand: ['memberships']})

all_projects = client.projects.find_all(workspace: $workspace.id, archived: false, per_page: 100, options: opts)
target_projects = all_projects.reject{|p| have_to_expect?(p)}

# 現在activeなプロジェクトをプロジェクトフォルダへcopy or update
pre_section = nil
target_projects.each_with_index do |project, i|
  same_section = project.select_same_section($sections_in_project_folder_with_note, client)
  if same_section.nil?
    p "#{project.name}は新しいprojectだったので新規追加"
    changed_section = client.sections.create_in_project({project: target_project_folder.id}.merge(create_data(project, index: i, pre_task: pre_section)))
  else
    p "#{project.name}はすでにあるprojectだったので更新"
    changed_section = same_section
  end
  client.tasks.find_by_id(changed_section.id).update(update_data(project, index: i, pre_task: pre_section))
  # 移動をサポートしたら下記でもOK
  # opts = pre_section.nil? ? {before_section: $sections_in_project_folder.first.id} : {after_section: pre_section&.id}
  # changed_section.insert_in_project({project: target_project_folder.id}.merge(opts)) unless changed_section.id == $sections_in_project_folder.first.id
  add_tasks_sections_in_this_project(changed_section, project, client, target_project_folder)
  pre_section = changed_section
end

# プロジェクトフォルダ内のいらないtaskを削除
delete_sections = $sections_in_project_folder.reject do |section|
  project_ids = target_projects.map(&:id)
  notes_id = client.tasks.find_by_id(section.id, options: {fields: ['notes']}).notes.strip.to_i
  project_ids.include?(notes_id)
end

delete_sections.each do |section|
  delete_tasks = $tasks_in_project_folder_with_sections.select{|task| section.id == task.memberships.first&.[]('section')&.[]('id') }
  delete_tasks.each(&:delete)
  section.delete
end
