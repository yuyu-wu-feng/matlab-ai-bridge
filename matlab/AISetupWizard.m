classdef AISetupWizard < handle
    % First-run setup. Only the explicit live-test button calls a model.
    properties
        Figure
        Python
        Backend
        Agent
        Node
        Model
        First
        Idle
        Total
        Status
        SaveButton
        CheckButton
        LiveButton
        FinishButton
        DetectButton
        CancelButton
        Root
        ConfigFile
        Process = []
        Poller = []
        Job = ''
        Started
        Limit = 45
        Action = ''
        Busy = false
        Saved = false
        Agents = []
        LastReport = struct
        OpenAssistant = false
        PythonCandidates = {}
        RetryPython = false
    end
    methods
        function obj=AISetupWizard(configFile,visibility,openAssistant)
            obj.Root=fileparts(fileparts(mfilename('fullpath')));
            if nargin<1 || isempty(configFile), configFile=fullfile(obj.Root,'config.local.json'); end
            if nargin<2, visibility='on'; end
            if nargin<3, openAssistant=false; end
            obj.ConfigFile=configFile; obj.OpenAssistant=openAssistant;
            obj.Figure=uifigure('Name','MATLAB AI · 首次配置向导','Position',[180 100 800 700], ...
                'Visible',visibility,'CloseRequestFcn',@(~,~)delete(obj));
            g=uigridlayout(obj.Figure,[15 3]); g.ColumnWidth={160,'1x',130};
            g.RowHeight={44,30,32,32,32,32,32,32,32,32,30,'1x',32,32,30};
            g.Scrollable='on';
            t=uilabel(g,'Text','先检测环境，再保存配置。真实模型测试为可选步骤，可能产生用量。','WordWrap','on');
            t.Layout.Row=1; t.Layout.Column=[1 3];
            t=uilabel(g,'Text','① Python 3.11+ 与 Agent：支持手动填写绝对路径'); t.Layout.Row=2; t.Layout.Column=[1 3];
            obj.Python=obj.field(g,3,'Python 程序');
            b=uibutton(g,'Text','选择 Python','ButtonPushedFcn',@(~,~)obj.browse(obj.Python)); b.Layout.Row=3; b.Layout.Column=3;
            t=uilabel(g,'Text','Agent'); t.Layout.Row=4; t.Layout.Column=1;
            obj.Backend=uidropdown(g,'Items',{'Codex','Claude Code','DeepSeek Harness（实验性）'}, ...
                'ItemsData',{'codex','claude','deepseek_harness'},'ValueChangedFcn',@(~,~)obj.chooseBackend);
            obj.Backend.Layout.Row=4; obj.Backend.Layout.Column=2;
            obj.DetectButton=uibutton(g,'Text','检测环境','ButtonPushedFcn',@(~,~)obj.detect); obj.DetectButton.Layout.Row=4; obj.DetectButton.Layout.Column=3;
            obj.Agent=obj.field(g,5,'Agent 程序 / JS 入口');
            b=uibutton(g,'Text','选择 Agent','ButtonPushedFcn',@(~,~)obj.browse(obj.Agent)); b.Layout.Row=5; b.Layout.Column=3;
            obj.Node=obj.field(g,6,'Node（仅 JS 入口需要）');
            obj.Model=obj.field(g,7,'模型 ID');
            t=uilabel(g,'Text','Claude 可留空；其他后端填写自己的有效模型 ID。','WordWrap','on'); t.Layout.Row=7; t.Layout.Column=3;
            t=uilabel(g,'Text','② 等待时间（秒）：首次 / 中断填 0 表示关闭该项限制'); t.Layout.Row=8; t.Layout.Column=[1 3];
            obj.First=obj.number(g,9,'首次回答等待',120,0);
            obj.Idle=obj.number(g,10,'回答中断等待',90,0);
            obj.Total=obj.number(g,11,'整次请求等待',600,1);
            obj.Status=uitextarea(g,'Editable','off','Value',{'尚未检测。可直接点击“检测环境”，或先选择 Python。'; ...
                '仅检测当前用户的 PATH 和常见安装目录，不自动安装软件或登录账户。'});
            obj.Status.Layout.Row=12; obj.Status.Layout.Column=[1 3];
            obj.SaveButton=uibutton(g,'Text','保存配置','ButtonPushedFcn',@(~,~)obj.save); obj.SaveButton.Layout.Row=13; obj.SaveButton.Layout.Column=1;
            obj.CheckButton=uibutton(g,'Text','检查安装（不调用模型）','ButtonPushedFcn',@(~,~)obj.check(false)); obj.CheckButton.Layout.Row=13; obj.CheckButton.Layout.Column=2;
            obj.FinishButton=uibutton(g,'Text','完成','ButtonPushedFcn',@(~,~)obj.finish); obj.FinishButton.Layout.Row=13; obj.FinishButton.Layout.Column=3;
            obj.LiveButton=uibutton(g,'Text','测试模型连接（可能产生用量）','ButtonPushedFcn',@(~,~)obj.check(true)); obj.LiveButton.Layout.Row=14; obj.LiveButton.Layout.Column=[1 2];
            obj.CancelButton=uibutton(g,'Text','取消当前操作','ButtonPushedFcn',@(~,~)obj.cancel); obj.CancelButton.Layout.Row=14; obj.CancelButton.Layout.Column=3;
            t=uilabel(g,'Text','凭据由 Agent 自己管理。向导不收集 API Key；关闭向导不会保存未提交的内容。','WordWrap','on'); t.Layout.Row=15; t.Layout.Column=[1 3];
            obj.loadExisting;
            obj.refreshButtons;
        end
        function control=field(obj,g,row,label)
            t=uilabel(g,'Text',label); t.Layout.Row=row; t.Layout.Column=1;
            control=uieditfield(g,'text','ValueChangedFcn',@(~,~)obj.dirty);
            control.Layout.Row=row; control.Layout.Column=2;
        end
        function control=number(obj,g,row,label,value,minimum)
            t=uilabel(g,'Text',label); t.Layout.Row=row; t.Layout.Column=1;
            control=uieditfield(g,'numeric','Value',value,'Limits',[minimum 86400],'ValueChangedFcn',@(~,~)obj.dirty);
            control.Layout.Row=row; control.Layout.Column=2;
        end
        function loadExisting(obj)
            if ~isfile(obj.ConfigFile), return; end
            try
                c=jsondecode(fileread(obj.ConfigFile));
                if isfield(c,'python_executable'), obj.Python.Value=c.python_executable; end
                c=ai_backend_config(c); obj.Backend.Value=c.backend;
                obj.Agent.Value=c.([c.backend '_executable']); obj.Model.Value=c.model;
                if strcmp(obj.Model.Value,'__default__'), obj.Model.Value=''; end
                if isfield(c,'node_executable'), obj.Node.Value=c.node_executable; end
                obj.First.Value=c.first_output_timeout_seconds; obj.Idle.Value=c.idle_timeout_seconds; obj.Total.Value=c.timeout_seconds;
                obj.Saved=isfile(obj.Python.Value);
                obj.Status.Value={'已载入现有配置；保存时会备份原配置并保留其他字段。';'已有助手窗口需关闭后重新打开，才能读取向导保存的新配置。'};
                if ~obj.Saved
                    obj.Status.Value={'配置中的 Python 路径失效。请重新选择 Python 或清空路径后检测环境，再保存。'};
                end
            catch
                obj.Status.Value={'现有配置无法读取。请先备份并修复 config.local.json；向导不会覆盖损坏的 JSON。'};
            end
        end
        function browse(obj,field)
            if obj.Busy, return; end
            [f,p]=uigetfile({'*.exe;*.js;*.mjs;*.cjs','程序或 JavaScript 入口';'*.*','所有文件'},'选择本机程序');
            if isequal(f,0), return; end
            field.Value=fullfile(p,f); obj.dirty;
        end
        function dirty(obj)
            obj.Saved=false; obj.refreshButtons;
        end
        function chooseBackend(obj)
            obj.Agent.Value=''; obj.Model.Value=''; obj.Node.Value='';
            for i=1:numel(obj.Agents)
                a=obj.Agents(i);
                if strcmp(a.backend,obj.Backend.Value)
                    obj.Agent.Value=a.executable; obj.Node.Value=a.node_executable; obj.Model.Value=a.suggested_model;
                    break;
                end
            end
            obj.dirty;
        end
        function detect(obj)
            if obj.Busy, return; end
            obj.dirty; obj.PythonCandidates={}; obj.RetryPython=false;
            if isempty(strtrim(obj.Python.Value))
                obj.PythonCandidates=obj.findPython; obj.RetryPython=true;
                if isempty(obj.PythonCandidates)
                    obj.Status.Value={'没有找到 Python。请安装 Python 3.11+，再点击“选择 Python”。'}; return;
                end
                obj.Python.Value=obj.PythonCandidates{1}; obj.PythonCandidates(1)=[];
            end
            obj.start('discover',{},45);
        end
        function paths=findPython(~)
            paths={};
            try
                env=pyenv; if ~isempty(env.Executable), paths{end+1}=char(env.Executable); end
            catch
            end
            dirs=strsplit(getenv('PATH'),pathsep);
            for i=1:numel(dirs)
                if contains(lower(dirs{i}),'windowsapps'), continue; end
                paths{end+1}=fullfile(dirs{i},'python.exe');
            end
            home=getenv('USERPROFILE'); local=getenv('LOCALAPPDATA');
            patterns={fullfile(local,'Programs','Python','Python*','python.exe'), ...
                fullfile(home,'miniconda3','python.exe'),fullfile(home,'anaconda3','python.exe'), ...
                fullfile(home,'.cache','codex-runtimes','*','dependencies','python','python.exe')};
            for i=1:numel(patterns)
                entries=dir(patterns{i});
                for j=1:numel(entries), paths{end+1}=fullfile(entries(j).folder,entries(j).name); end
            end
            paths=unique(paths,'stable'); paths=paths(cellfun(@isfile,paths));
        end
        function save(obj)
            if obj.Busy, return; end
            args={'--config',obj.ConfigFile,'--backend',obj.Backend.Value,'--agent',obj.Agent.Value, ...
                '--node',obj.Node.Value,'--model',obj.Model.Value,'--first',num2str(obj.First.Value,15), ...
                '--idle',num2str(obj.Idle.Value,15),'--total',num2str(obj.Total.Value,15)};
            if isfile(obj.ConfigFile), args{end+1}='--overwrite'; end
            obj.RetryPython=false; obj.Saved=false; obj.start('configure',args,30);
        end
        function check(obj,live)
            if obj.Busy || ~obj.Saved, return; end
            args={'--config',obj.ConfigFile}; limit=30;
            if live, args{end+1}='--live'; limit=obj.Total.Value+30; end
            obj.RetryPython=false; obj.start('check',args,limit);
        end
        function start(obj,action,args,limit)
            if ~isfile(obj.Python.Value)
                obj.Status.Value={'Python 路径不存在。请选择 python.exe 后重试。'}; obj.refreshButtons; return;
            end
            obj.Action=action; obj.Limit=limit; obj.Started=tic;
            obj.Job=tempname; mkdir(obj.Job);
            allArgs=[{'-B',fullfile(obj.Root,'setup_cli.py'),action},args,{'--output',fullfile(obj.Job,'report.json')}];
            try
                % File paths cannot contain quotes. No shell or expression evaluation.
                if any(cellfun(@(s)any(s=='"' | double(s)<32),allArgs)), error('MatlabAI:Setup','参数包含不支持的引号或控制字符。'); end
                quoted=cellfun(@(s)['"' s '"'],allArgs,'UniformOutput',false);
                info=System.Diagnostics.ProcessStartInfo;
                info.FileName=obj.Python.Value; info.Arguments=strjoin(quoted,' ');
                info.UseShellExecute=false; info.CreateNoWindow=true; info.WorkingDirectory=obj.Root;
                obj.Process=System.Diagnostics.Process.Start(info);
                obj.Busy=true; obj.Status.Value={'正在执行配置检查，请稍候…';'可取消当前操作。模型测试使用固定示例，不读取编辑器内容。'};
                obj.refreshButtons;
                obj.Poller=timer('ExecutionMode','fixedSpacing','Period',0.2,'TimerFcn',@(~,~)obj.poll, ...
                    'ErrorFcn',@(~,~)obj.pollFailed);
                start(obj.Poller);
            catch e
                obj.cleanJob; obj.Busy=false; obj.refreshButtons;
                obj.Status.Value={['无法启动配置检查：' e.message]};
            end
        end
        function poll(obj)
            if ~obj.Busy, return; end
            if ~obj.Process.HasExited
                if toc(obj.Started)>obj.Limit, obj.cancel; obj.Status.Value={'配置操作超时。请检查程序路径；模型测试可调大等待时间并重新保存后重试。'}; end
                return;
            end
            reportFile=fullfile(obj.Job,'report.json');
            report=struct('ok',false,'message','程序未返回配置报告。请确认 Python 版本至少为 3.11。');
            try
                if isfile(reportFile), report=jsondecode(fileread(reportFile)); end
            catch
                report.message='无法读取配置报告，请重新检测。';
            end
            obj.cleanJob; obj.Busy=false; obj.LastReport=report;
            if ~report.ok && obj.RetryPython && ~isempty(obj.PythonCandidates)
                obj.Python.Value=obj.PythonCandidates{1}; obj.PythonCandidates(1)=[]; obj.start('discover',{},45); return;
            end
            if report.ok && strcmp(obj.Action,'discover')
                obj.Python.Value=report.python_executable; obj.Agents=report.agents;
                lines={['Python ' report.python_version ' 可用。']};
                for i=1:numel(obj.Agents)
                    a=obj.Agents(i); lines{end+1}=[a.backend '：' a.message];
                end
                % Preserve the selected backend; detection never changes providers.
                if isempty(obj.Agent.Value) && isempty(obj.Model.Value)
                    obj.chooseBackend;
                end
                lines{end+1}='请核对 Agent 与模型 ID，点击“保存配置”。检测到程序不等于已登录。'; obj.Status.Value=lines;
            else
                obj.Status.Value={report.message};
                if report.ok && strcmp(obj.Action,'configure'), obj.Saved=true; end
            end
            obj.refreshButtons;
        end
        function refreshButtons(obj)
            if isempty(obj.Figure) || ~isvalid(obj.Figure), return; end
            enabled=matlab.lang.OnOffSwitchState(~obj.Busy);
            controls={obj.Python,obj.Backend,obj.Agent,obj.Node,obj.Model,obj.First,obj.Idle,obj.Total,obj.SaveButton,obj.DetectButton};
            for i=1:numel(controls), controls{i}.Enable=enabled; end
            checked=matlab.lang.OnOffSwitchState(~obj.Busy && obj.Saved);
            obj.CheckButton.Enable=checked; obj.LiveButton.Enable=checked; obj.FinishButton.Enable=checked;
            obj.CancelButton.Enable=matlab.lang.OnOffSwitchState(obj.Busy);
        end
        function pollFailed(obj)
            obj.cancel;
            if isvalid(obj.Figure), obj.Status.Value={'处理配置报告失败，已结束本次检查。可以重新检测或手动选择程序。'}; end
        end
        function cancel(obj)
            if ~isempty(obj.Process)
                try
                    if ~obj.Process.HasExited
                        info=System.Diagnostics.ProcessStartInfo;
                        info.FileName=fullfile(getenv('SystemRoot'),'System32','taskkill.exe');
                        info.Arguments=sprintf('/PID %d /T /F',obj.Process.Id);
                        info.UseShellExecute=false; info.CreateNoWindow=true;
                        killer=System.Diagnostics.Process.Start(info); killer.WaitForExit(3000); killer.Dispose;
                    end
                catch
                    try, obj.Process.Kill; catch, end
                end
            end
            obj.cleanJob; obj.Busy=false; obj.refreshButtons;
            if isvalid(obj.Figure), obj.Status.Value={'当前操作已取消。已成功保存的配置仍保留；可重新检测或保存。'}; end
        end
        function cleanJob(obj)
            if ~isempty(obj.Poller)
                try, stop(obj.Poller); delete(obj.Poller); catch, end
                obj.Poller=[];
            end
            if ~isempty(obj.Process), try, obj.Process.Dispose; catch, end; obj.Process=[]; end
            if ~isempty(obj.Job) && isfolder(obj.Job), try, rmdir(obj.Job,'s'); catch, end; end
            obj.Job='';
        end
        function finish(obj)
            if ~obj.Saved || obj.Busy, return; end
            reopen=obj.OpenAssistant; delete(obj);
            if reopen, matlab_ai; end
        end
        function delete(obj)
            obj.cancel;
            if ~isempty(obj.Figure) && isvalid(obj.Figure), delete(obj.Figure); end
        end
    end
end
