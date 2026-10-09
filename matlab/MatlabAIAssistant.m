classdef MatlabAIAssistant < handle
    % Standalone MATLAB UI; network requests run in a separate Python process.
    properties (SetAccess = private)
        Figure
        Question
        Mode
        Scope
        Model
        ModelRefreshButton
        SettingsTab
        SettingsButton
        BackendPicker
        ExecutableField
        BackendModelField
        TotalWait
        FirstWait
        IdleWait
        SettingsSaveButton
        ModelCatalog = struct('id',{},'name',{},'effort',{},'source',{})
        IsLoadingModels = false
        ModelSource = ''
        GeneratedCode
        GeneratedTab
        InsertButton
        NewDocumentButton
        GeneratedText = ''
        GeneratedConsumed = false
        RequestMode = ''
        ContextLabel
        Status
        Answer
        Before
        After
        Diff
        Tabs
        SendButton
        CancelButton
        ApplyButton
        RestoreButton
        CaptureButton
        Transaction = []
        LastApplied = []
        IsBusy = false
        LastError = ''
        LastResponse = struct
        RequestID = ''
        Store = []
        ContinueCheck
        NewConversationButton
        RepairButton
        ConversationLabel
        HistoryPicker
        HistoryTable
        HistoryDetail
        HistoryTab
        ReuseButton
        CompareButton
        FontPicker
        CheckView
        CheckTab
        CheckReport = struct
        ChangeTable
        PreviewKind = ''
        ChangeBlocks = struct([])
        SelectedHistory = 0
        StreamChunks = 0
        RequestHistoryCount = 0
        HelpTab
        HelpAnswer
        HelpSources
        HelpTopic
        HelpContext = struct
        SimulinkTab
        SimulinkTarget
        SimulinkSnapshot
        SimulinkAnswer
        SimulinkPlan
    end
    properties (Access = private)
        Root
        Config
        ConfigFile
        Job = ''
        Process = []
        PollTimer = []
        WatchdogTimer = []
        CancelStarted = []
        AbortReason = ''
        Reaper = []
        Cancelled = false
        Closing = false
        CatalogProcess = []
        CatalogJob = ''
        RequestQuestion = ''
        RequestStarted = []
        LastProgressChunks = -1
        LastPhase = 'connecting'
    end
    methods
        function obj = MatlabAIAssistant(visibility,historyFolder,configFile)
            if nargin < 1, visibility = 'on'; end
            obj.Root = fileparts(fileparts(mfilename('fullpath')));
            if nargin<3, configFile = fullfile(obj.Root, 'config.local.json'); end
            obj.ConfigFile=configFile;
            if ~isfile(configFile)
                error('MatlabAI:Configuration', '请运行 start_ai.m 或 matlab_ai_setup，通过配置向导填写本机环境。');
            end
            obj.Config = ai_backend_config(jsondecode(fileread(configFile)));
            if nargin<2
                if strcmp(visibility,'off'), historyFolder='';
                else, historyFolder=fullfile(obj.Root,'output','history'); end
            end
            obj.Store = AIConversationStore(historyFolder);
            obj.buildUI(visibility);
            obj.PollTimer = timer('ExecutionMode','fixedSpacing', 'Period',0.3, ...
                'Name',['MatlabAI-Poll-' char(java.util.UUID.randomUUID)], ...
                'BusyMode','drop', 'TimerFcn',@(~,~) obj.poll, ...
                'ErrorFcn',@(~,~) obj.pollError);
            obj.WatchdogTimer = timer('ExecutionMode','fixedSpacing','Period',1, ...
                'BusyMode','drop','TimerFcn',@(~,~) obj.watchdog);
            start(obj.WatchdogTimer);
            obj.setStatus('就绪。输入需求生成代码，或选择解释、修改、续写已有代码。');
            obj.refreshHistory;
            obj.loadPreferences;
            obj.refreshModels;
        end

        function refreshModels(obj)
            if obj.IsBusy || obj.IsLoadingModels, return; end
            jobs = fullfile(obj.Root,'output','model-jobs');
            if ~isfolder(jobs), mkdir(jobs); end
            obj.CatalogJob = fullfile(jobs,char(java.util.UUID.randomUUID));
            mkdir(obj.CatalogJob);
            try
                info = System.Diagnostics.ProcessStartInfo;
                info.FileName = obj.Config.python_executable;
                info.Arguments = sprintf('-B "%s" --config "%s" --response "%s"', ...
                    fullfile(obj.Root,'backend','model_catalog.py'), ...
                    obj.ConfigFile,fullfile(obj.CatalogJob,'models.json'));
                info.WorkingDirectory = obj.Root;
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                obj.CatalogProcess = System.Diagnostics.Process;
                obj.CatalogProcess.StartInfo = info;
                if ~obj.CatalogProcess.Start, error('MatlabAI:Models','无法启动模型列表读取。'); end
                obj.IsLoadingModels = true;
                obj.updateButtons;
                obj.ModelRefreshButton.Text = '读取中…';
                obj.Model.Tooltip = '正在检查所选 Agent 与模型配置。';
                if strcmp(obj.PollTimer.Running,'off'), start(obj.PollTimer); end
            catch exception
                obj.finishModelRefresh;
                obj.setStatus(['读取模型失败：' exception.message]);
            end
        end

        function ensureModelPicker(obj)
            % Upgrade an already-open v0.1 window without discarding its draft,
            % preview or last-apply recovery snapshot.
            if isa(obj.Model,'matlab.ui.control.DropDown'), return; end
            if obj.IsBusy, error('MatlabAI:Busy','请等待当前提问结束后再打开更新后的助手。'); end
            controls = obj.Model.Parent;
            initial = obj.Model.Value;
            controls.ColumnWidth = {40,90,40,120,40,'1x',90,120};
            delete(obj.Model);
            obj.Model = uidropdown(controls,'Items',{initial},'ItemsData',{initial}, ...
                'Value',initial,'Editable','off','ValueChangedFcn',@(~,~) obj.invoke(@() obj.modelChanged));
            obj.Model.Layout.Row = 1; obj.Model.Layout.Column = 6;
            obj.ModelRefreshButton = uibutton(controls,'Text','刷新模型','ButtonPushedFcn',@(~,~) obj.refreshModels);
            obj.ModelRefreshButton.Layout.Row = 1; obj.ModelRefreshButton.Layout.Column = 7;
            obj.CaptureButton.Layout.Column = 8;
            obj.refreshModels;
        end

        function current = upgradeWindow(obj)
            current = obj;
            if isempty(obj.ConfigFile), obj.ConfigFile=fullfile(obj.Root,'config.local.json'); end
            obj.Config=ai_backend_config(obj.Config);
            if isempty(obj.SettingsTab) || ~isvalid(obj.SettingsTab), obj.buildSettingsTab; end
            obj.Mode.Parent.ColumnWidth={40,115,40,145,40,'1x',90,120};
            if ~ismember('sim_edit',obj.Mode.ItemsData)
                previous=obj.Mode.Value;
                obj.Mode.ItemsData={};
                obj.Mode.Items={'需求生成','查询帮助','解释','修改','续写','解释模型','修改模型','修改模块代码'};
                obj.Mode.ItemsData={'generate','help','explain','edit','complete','sim_explain','sim_edit','sim_function'};
                obj.Mode.Value=previous;
                obj.buildSimulinkTab;
            end
            % Add the help surface in place, preserving drafts and pending edits.
            if isempty(obj.HelpTab) || ~isvalid(obj.HelpTab), obj.buildHelpTab; end
            if ~isempty(obj.ContinueCheck) && isvalid(obj.ContinueCheck) && ...
                    ~isempty(obj.WatchdogTimer) && isvalid(obj.WatchdogTimer), return; end
            if obj.IsBusy || obj.IsLoadingModels
                error('MatlabAI:Busy','请等待当前请求或模型刷新结束后，再打开更新后的助手。');
            end
            % Preserve the user's draft, pending preview and recovery handle.
            current = MatlabAIAssistant('off',fullfile(obj.Root,'output','history'));
            current.Question.Value = obj.Question.Value;
            current.Mode.Value = obj.Mode.Value;
            current.Scope.Value = obj.Scope.Value;
            current.Answer.Value = obj.Answer.Value;
            current.Before.Value = obj.Before.Value;
            current.After.Value = obj.After.Value;
            current.Diff.HTMLSource = obj.Diff.HTMLSource;
            current.Transaction = obj.Transaction;
            current.LastApplied = obj.LastApplied;
            current.LastResponse = obj.LastResponse;
            current.GeneratedText = obj.GeneratedText;
            current.GeneratedConsumed = obj.GeneratedConsumed;
            current.RequestMode = obj.RequestMode;
            current.GeneratedCode.Value = obj.GeneratedCode.Value;
            if ~isempty(obj.Store), current.Store = obj.Store; current.refreshHistory; end
            current.ApplyButton.Enable = obj.ApplyButton.Enable;
            current.RestoreButton.Enable = obj.RestoreButton.Enable;
            current.ContextLabel.Text = obj.ContextLabel.Text;
            current.Figure.Position = obj.Figure.Position;
            current.Figure.Visible = obj.Figure.Visible;
            delete(obj);
        end

        function openSettings(obj)
            obj.Tabs.SelectedTab=obj.SettingsTab;
        end

        function value = backendSettings(obj)
            value=obj.Config;
        end

        function buildSettingsTab(obj)
            obj.SettingsTab=uitab(obj.Tabs,'Title','后端与等待设置');
            g=uigridlayout(obj.SettingsTab,[9 2]);
            g.ColumnWidth={155,'1x'}; g.RowHeight={28,28,28,26,26,26,32,30,30};
            g.RowSpacing=4; g.Padding=[10 6 10 6]; g.Scrollable='on';
            uilabel(g,'Text','Agent');
            obj.BackendPicker=uidropdown(g,'Items',{'Codex','Claude Code','DeepSeek Harness（实验性）'}, ...
                'ItemsData',{'codex','claude','deepseek_harness'},'Value',obj.Config.backend, ...
                'ValueChangedFcn',@(~,~) obj.backendFormChanged);
            uilabel(g,'Text','Agent 程序路径');
            obj.ExecutableField=uieditfield(g,'text','Placeholder','留空自动查找；支持原生程序或 .js 入口');
            uilabel(g,'Text','模型 ID');
            obj.BackendModelField=uieditfield(g,'text','Placeholder','Claude 留空使用默认模型；其他 Agent 填模型 ID');
            uilabel(g,'Text','首次回答等待（秒）');
            obj.FirstWait=uieditfield(g,'numeric','Limits',[0 86400],'Value',obj.Config.first_output_timeout_seconds);
            uilabel(g,'Text','回答中断等待（秒）');
            obj.IdleWait=uieditfield(g,'numeric','Limits',[0 86400],'Value',obj.Config.idle_timeout_seconds);
            uilabel(g,'Text','整次请求等待（秒）');
            obj.TotalWait=uieditfield(g,'numeric','Limits',[1 86400],'Value',obj.Config.timeout_seconds);
            note=uilabel(g,'Text','首次/中断填 0 可关闭对应限制；总等待仍生效。等待时间不是模型思考强度。DeepSeek 实验适配使用 DEEPSEEK_API_KEY 环境变量。', ...
                'WordWrap','on'); note.Layout.Column=[1 2];
            uibutton(g,'Text','较慢模型预设','ButtonPushedFcn',@(~,~) obj.slowModelPreset);
            obj.SettingsSaveButton=uibutton(g,'Text','保存并检查安装', ...
                'ButtonPushedFcn',@(~,~) obj.invoke(@() obj.saveBackendForm));
            note=uilabel(g,'Text','检查安装不调用模型、不产生模型用量；模型是否可用仍需发送问题验证。配置按 Agent 记住模型，等待设置对全部 Agent 生效。', ...
                'WordWrap','on'); note.Layout.Column=[1 2];
            obj.backendFormChanged;
        end

        function slowModelPreset(obj)
            obj.FirstWait.Value=120; obj.IdleWait.Value=90; obj.TotalWait.Value=600;
        end

        function backendFormChanged(obj)
            name=obj.BackendPicker.Value;
            field=[name '_executable'];
            obj.ExecutableField.Value=obj.Config.(field);
            model='';
            if strcmp(name,obj.Config.backend), model=obj.Config.model;
            elseif isfield(obj.Config.backend_models,name), model=obj.Config.backend_models.(name); end
            if strcmp(model,'__default__'), model=''; end
            obj.BackendModelField.Value=model;
        end

        function saveBackendForm(obj)
            options=struct('backend',obj.BackendPicker.Value,'model',strtrim(obj.BackendModelField.Value), ...
                'timeout_seconds',obj.TotalWait.Value,'first_output_timeout_seconds',obj.FirstWait.Value, ...
                'idle_timeout_seconds',obj.IdleWait.Value);
            options.([options.backend '_executable'])=strtrim(obj.ExecutableField.Value);
            obj.configureBackend(options);
            obj.refreshModels;
        end

        function configureBackend(obj,options)
            if obj.IsBusy || obj.IsLoadingModels
                error('MatlabAI:Busy','请等当前请求或检查完成后再保存设置。');
            end
            latest=ai_backend_config(jsondecode(fileread(obj.ConfigFile)));
            fields=fieldnames(options);
            allowed={'backend','model','timeout_seconds','first_output_timeout_seconds','idle_timeout_seconds', ...
                'codex_executable','claude_executable','deepseek_harness_executable'};
            for k=1:numel(fields)
                if ~ismember(fields{k},allowed), error('MatlabAI:Configuration','不支持此设置。'); end
                latest.(fields{k})=options.(fields{k});
            end
            latest=ai_backend_config(latest);
            limits=[latest.first_output_timeout_seconds latest.idle_timeout_seconds latest.timeout_seconds];
            if any(~isfinite(limits)) || any(limits<0) || any(limits>86400) || limits(3)<1 || any(limits(1:2)>limits(3))
                error('MatlabAI:Configuration','等待时间无效：总等待需为 1–86400 秒且不能小于首次/中断等待。');
            end
            if isempty(latest.model) && strcmp(latest.backend,'claude'), latest.model='__default__'; end
            latest.backend_models.(obj.Config.backend)=obj.Config.model;
            latest.backend_models.(latest.backend)=latest.model;
            temporary=[obj.ConfigFile '.' char(java.util.UUID.randomUUID) '.tmp'];
            writeUTF8(temporary,jsonencode(latest,PrettyPrint=true));
            [ok,message]=movefile(temporary,obj.ConfigFile,'f');
            if ~ok, error('MatlabAI:Configuration','无法保存设置：%s',message); end
            obj.Config=latest;
            obj.Model.ItemsData={};
            label=latest.model; if isempty(label), label='请填写模型 ID'; end
            if strcmp(label,'__default__'), label='使用 Claude 默认模型'; end
            obj.Model.Items={label}; obj.Model.ItemsData={latest.model}; obj.Model.Value=latest.model;
            obj.BackendPicker.Value=latest.backend;
            obj.FirstWait.Value=limits(1); obj.IdleWait.Value=limits(2); obj.TotalWait.Value=limits(3);
            obj.backendFormChanged;
            obj.invalidatePreview;
            obj.updateButtons;
            obj.setStatus('设置已保存，下次请求生效。');
        end

        function modelChanged(obj)
            % Persist only the project model preference, not global Codex settings.
            configFile = obj.ConfigFile;
            latest = ai_backend_config(jsondecode(fileread(configFile)));
            latest.model = obj.Model.Value;
            latest.backend_models.(obj.Config.backend)=obj.Model.Value;
            temporary = [configFile '.' char(java.util.UUID.randomUUID) '.tmp'];
            writeUTF8(temporary,jsonencode(latest,PrettyPrint=true));
            [ok,message] = movefile(temporary,configFile,'f');
            if ~ok, error('MatlabAI:Configuration','无法保存模型选择：%s',message); end
            obj.Config.model = obj.Model.Value;
            obj.Config.backend_models.(obj.Config.backend)=obj.Model.Value;
            obj.BackendModelField.Value=obj.Model.Value;
            obj.invalidatePreview;
            obj.setStatus(['已选择模型：' obj.Model.Value]);
        end

        function capture(obj)
            if obj.IsBusy, return; end
            if startsWith(obj.Mode.Value,'sim_')
                target=strtrim(obj.SimulinkTarget.Value);
                if isempty(target), error('MatlabAI:SimModel','请在 Simulink 页指定目标模型，或点击“使用当前模型”。'); end
                scope=obj.Scope.Value;
                if strcmp(obj.Mode.Value,'sim_function'), scope='selection'; end
                obj.Transaction=AISimulinkTransaction(target,obj.Mode.Value,scope);
                obj.SimulinkSnapshot.Value=textLines(obj.Transaction.Context);
                obj.ContextLabel.Text=sprintf('Simulink 目标：%s · %d 个选中模块 · 发送结构、参数和模块函数代码',target,numel(obj.Transaction.Selected));
                obj.Before.Value=textLines(obj.Transaction.BaseText);
                obj.ApplyButton.Enable='off'; obj.SimulinkPlan.Data=cell(0,3);
                obj.Tabs.SelectedTab=obj.SimulinkTab;
                obj.setStatus('已读取指定模型；发送时会重新读取，应用前会检查模型是否变化。');
                return;
            end
            if strcmp(obj.Mode.Value,'help')
                obj.Transaction=[];
                previous='';
                if obj.ContinueCheck.Value
                    history=obj.Store.context(true);
                    for k=max(1,numel(history)-1):numel(history)
                        previous=[previous ' ' history{k}.question];
                    end
                end
                obj.HelpContext=ai_help_context(char(strjoin(string(obj.Question.Value),newline)),previous);
                obj.showHelpSources;
                obj.ContextLabel.Text='查询帮助：发送问题、本机函数帮助、版本及工具箱清单；继续对话仅携带帮助问答。';
                obj.Before.Value={''};
                obj.Tabs.SelectedTab=obj.HelpTab;
                return;
            end
            if strcmp(obj.Mode.Value,'generate')
                obj.Transaction = [];
                obj.ContextLabel.Text = '需求生成：发送需求及启用的最近对话，不读取编辑器。生成后可预览插入或新建文档。';
                obj.Before.Value = {''};
                return;
            end
            obj.Transaction = AIEditorTransaction(matlab.desktop.editor.getActive, obj.Mode.Value, obj.Scope.Value);
            obj.showContext;
            obj.ApplyButton.Enable = 'off';
            obj.After.Value = {''};
            obj.Diff.HTMLSource = '<html><body style="font-family:sans-serif;color:#64748b;padding:20px">发送问题后，在这里查看逐行差异。</body></html>';
            obj.setStatus('已读取当前编辑器内容；发送时会再次读取最新内容。');
        end

        function ask(obj, question, mode, scope)
            if obj.IsBusy, error('MatlabAI:Busy','当前请求尚未结束。'); end
            if obj.IsLoadingModels, error('MatlabAI:ModelsLoading','正在读取模型列表，请稍候。'); end
            if isempty(obj.Model.Value), error('MatlabAI:NoModels','请先刷新并选择模型。'); end
            if nargin > 1, obj.Question.Value = splitlines(string(question)); end
            if nargin > 2, obj.Mode.Value = mode; obj.modeChanged; end
            if nargin > 3, obj.Scope.Value = scope; end
            if strcmp(obj.Mode.Value,'sim_function'), obj.Scope.Value='selection'; end
            question = char(strjoin(string(obj.Question.Value), newline));
            if isempty(strtrim(question)), error('MatlabAI:Question','请先输入问题。'); end
            if ~isfile(obj.Config.python_executable)
                error('MatlabAI:Configuration','Python 路径无效，请检查配置。');
            end
            obj.capture;
            obj.RequestMode = obj.Mode.Value;
            obj.RequestQuestion = question;
            obj.PreviewKind = '';
            obj.ChangeBlocks = struct([]);
            obj.ChangeTable.Data = cell(0,4);
            obj.GeneratedText = '';
            obj.GeneratedConsumed = false;
            obj.GeneratedCode.Value = {''};
            obj.InsertButton.Enable = 'off';
            obj.NewDocumentButton.Enable = 'off';
            obj.ApplyButton.Enable = 'off';
            obj.LastError = '';
            obj.LastResponse = struct;
            obj.Answer.Value = {'正在请求模型… 你可以继续在编辑器中工作。'};
            obj.Cancelled = false;
            obj.CancelStarted = [];
            obj.AbortReason = '';
            obj.RequestID = char(java.util.UUID.randomUUID);
            jobs = fullfile(obj.Root, 'output', 'jobs');
            if ~isfolder(jobs), mkdir(jobs); end
            obj.Job = fullfile(jobs, obj.RequestID);
            mkdir(obj.Job);
            if ismember(obj.RequestMode,{'generate','help'}), context = ''; else, context = obj.Transaction.Context; end
            request = struct('request_id', obj.RequestID, 'question', question, ...
                'code', context, 'mode', obj.RequestMode, ...
                'model', obj.Model.Value,'stream',true);
            request.history = {};
            if obj.ContinueCheck.Value, request.history = obj.Store.context(strcmp(obj.RequestMode,'help')); end
            if startsWith(obj.RequestMode,'sim_')
                request.history=request.history(cellfun(@(turn) startsWith(turn.mode,'sim_'),request.history));
                obj.SimulinkAnswer.Value={'正在根据模型快照整理回答…'};
            end
            if strcmp(obj.RequestMode,'help')
                request.help_context=obj.HelpContext;
                request.help_context.documents=num2cell(obj.HelpContext.documents);
                request.help_context.products=num2cell(obj.HelpContext.products);
                obj.HelpAnswer.Value={'正在根据本机资料整理回答… 下方资料可直接查看。'};
            end
            obj.RequestHistoryCount = numel(request.history);
            obj.StreamChunks = 0;
            obj.LastProgressChunks = -1;
            obj.LastPhase = 'connecting';
            obj.RequestStarted = tic;
            if strcmp(obj.Config.backend,'codex'), request.reasoning_effort = 'low'; end
            if strcmp(obj.RequestMode, 'complete')
                request.before_cursor = obj.Transaction.BeforeCursor;
                request.after_cursor = obj.Transaction.AfterCursor;
            end
            writeUTF8(fullfile(obj.Job, 'request.json'), jsonencode(request));
            % Bind this request and its watchdog to the same configuration snapshot.
            writeUTF8(fullfile(obj.Job, 'config.json'), jsonencode(obj.Config));
            try
                info = System.Diagnostics.ProcessStartInfo;
                info.FileName = obj.Config.python_executable;
                info.Arguments = sprintf('-B "%s" --request "%s" --response "%s" --config "%s"', ...
                    fullfile(obj.Root,'backend','worker.py'), fullfile(obj.Job,'request.json'), ...
                    fullfile(obj.Job,'response.json'), fullfile(obj.Job,'config.json'));
                info.WorkingDirectory = obj.Root;
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                obj.Process = System.Diagnostics.Process;
                obj.Process.StartInfo = info;
                if ~obj.Process.Start, error('MatlabAI:Worker','无法启动模型进程。'); end
                obj.IsBusy = true;
                obj.updateButtons;
                start(obj.PollTimer);
                obj.setStatus('正在生成回答… 可取消；代码仍可继续编辑。');
            catch exception
                obj.finishJob;
                rethrow(exception);
            end
        end

        function cancel(obj)
            if ~obj.IsBusy, return; end
            if isempty(obj.CancelStarted), obj.CancelStarted = tic; end
            obj.Cancelled = true;
            writeUTF8(fullfile(obj.Job,'cancel.flag'), 'cancel');
            obj.ApplyButton.Enable = 'off';
            obj.CancelButton.Enable = 'off';
            obj.setStatus('已取消请求，正在结束后台任务。');
        end

        function value = runtimeStatus(obj)
            value=struct('busy',obj.IsBusy,'poll_timer',obj.PollTimer.Running, ...
                'poll_timer_name',obj.PollTimer.Name,'watchdog_timer',obj.WatchdogTimer.Running, ...
                'reasoning_effort','low','elapsed_seconds',0,'worker_running',false);
            if obj.IsBusy
                value.elapsed_seconds=toc(obj.RequestStarted);
                value.worker_running=~isempty(obj.Process) && ~obj.Process.HasExited;
            end
        end

        function apply(obj)
            if obj.IsBusy || isempty(obj.Transaction)
                error('MatlabAI:NoProposal','当前没有可应用的修改。');
            end
            if ~isempty(obj.ChangeBlocks) && ~any(cell2mat(obj.ChangeTable.Data(:,1)))
                error('MatlabAI:NoSelection','请至少选择一处修改。');
            end
            try
                obj.Transaction.apply;
            catch exception
                if isa(obj.Transaction,'AISimulinkTransaction') && obj.Transaction.Applied
                    obj.LastApplied=obj.Transaction; obj.RestoreButton.Enable='on';
                end
                rethrow(exception);
            end
            obj.LastApplied = obj.Transaction;
            if strcmp(obj.PreviewKind,'insert'), obj.GeneratedConsumed = true; end
            obj.ApplyButton.Enable = 'off';
            obj.ChangeTable.Enable = 'off';
            obj.RestoreButton.Enable = 'on';
            obj.updateButtons;
            if isa(obj.Transaction,'AISimulinkTransaction')
                obj.setStatus('已应用到指定模型，尚未保存或仿真；可点击“恢复上次修改”。');
            else
                obj.setStatus('已应用到原文档的未保存缓冲区。可点击“恢复上次修改”。');
            end
        end

        function restore(obj)
            if obj.IsBusy || isempty(obj.LastApplied)
                error('MatlabAI:NoRestore','没有可恢复的修改。');
            end
            obj.LastApplied.restore;
            obj.RestoreButton.Enable = 'off';
            if obj.GeneratedConsumed && isequal(obj.LastApplied,obj.Transaction)
                obj.GeneratedConsumed = false;
                obj.updateButtons;
            end
            obj.setStatus('已按快照恢复应用前内容；没有保存到磁盘。');
        end

        function insertGenerated(obj, newDocument)
            if nargin < 2, newDocument = false; end
            if obj.IsBusy || isempty(obj.GeneratedText) || obj.GeneratedConsumed
                error('MatlabAI:NoGeneratedCode','请先生成代码，或恢复上一次插入。');
            end
            if newDocument
                doc = matlab.desktop.editor.newDocument('');
            else
                doc = matlab.desktop.editor.getActive;
            end
            transaction = AIEditorTransaction(doc,'complete','cursor');
            replacement = obj.GeneratedText;
            % Keep a generated script on its own lines at the insertion point.
            if ~isempty(transaction.BeforeCursor) && ~endsWith(transaction.BeforeCursor,newline)
                replacement = [newline replacement];
            end
            if ~endsWith(replacement,newline) && ~isempty(transaction.AfterCursor) && ~startsWith(transaction.AfterCursor,newline)
                replacement = [replacement newline];
            end
            transaction.propose(replacement);
            obj.Transaction = transaction;
            obj.PreviewKind = 'insert';
            obj.preparePreview;
            if newDocument
                obj.apply;
            else
                obj.Tabs.SelectedTab = obj.Diff.Parent.Parent;
                obj.ApplyButton.Text = '确认插入';
                obj.ApplyButton.Enable = 'on';
            end
            obj.updateButtons;
            obj.ContextLabel.Text = sprintf('目标：%s · 第 %d 行，第 %d 列 · 未保存缓冲区', ...
                transaction.Filename,transaction.Selection(1),transaction.Selection(2));
            if newDocument, obj.setStatus('已放入新文档，尚未保存或执行。');
            else, obj.setStatus('插入预览已就绪，检查目标和差异后点击“确认插入”。'); end
        end

        function newConversation(obj)
            if obj.IsBusy, error('MatlabAI:Busy','请先等待或取消当前请求。'); end
            obj.Store.fresh;
            obj.Question.Value = {''};
            obj.Answer.Value = {'新对话。可以输入需求，也可以粘贴报错后点击“按报错修正”。'};
            obj.HelpContext=struct;
            obj.HelpAnswer.Value={'输入函数、概念或工具箱问题。'};
            obj.HelpSources.Value={'尚未查询本机资料。'};
            obj.HelpTopic.ItemsData={}; obj.HelpTopic.Items={'尚未查询'}; obj.HelpTopic.ItemsData={''};
            if ~isempty(obj.SimulinkAnswer)
                obj.SimulinkAnswer.Value={'读取模型后提问。'}; obj.SimulinkPlan.Data=cell(0,3);
            end
            obj.invalidatePreview;
            obj.GeneratedCode.Value = {''};
            obj.Before.Value = {''}; obj.After.Value = {''};
            obj.Diff.HTMLSource = ai_diff_html('','');
            obj.CheckView.Value = {'生成后自动进行静态检查，不运行代码。'};
            obj.refreshHistory;
            obj.savePreferences;
            obj.setStatus('已开始新对话，后续提问不携带旧对话。');
        end

        function repairFromError(obj)
            if strcmp(obj.Mode.Value,'help'), error('MatlabAI:HelpOnly','请切换到需求生成或修改模式后修正代码。'); end
            if strcmp(obj.Mode.Value,'sim_explain'), obj.Mode.Value='sim_edit'; end
            text = char(strjoin(string(obj.Question.Value),newline));
            if isempty(strtrim(text)), error('MatlabAI:ErrorText','请先在问题框粘贴报错信息或描述问题。'); end
            if strcmp(obj.Mode.Value,'generate') && isempty(obj.Store.Turns)
                error('MatlabAI:NoHistory','请先生成代码，或选择“修改”来修复编辑器中的代码。');
            end
            if strcmp(obj.Mode.Value,'explain'), obj.Mode.Value='edit'; end
            obj.ContinueCheck.Value = true;
            obj.ask(sprintf('请根据以下报错或问题修正代码，解释原因并返回完整修正版；不要自动运行。\n%s',text));
        end

        function loadConversation(obj,id)
            if obj.IsBusy, error('MatlabAI:Busy','请先结束当前请求。'); end
            obj.Store.load(id);
            obj.invalidatePreview;
            obj.Question.Value = {''};
            obj.refreshHistory;
            obj.viewHistory(numel(obj.Store.Turns));
            obj.Tabs.SelectedTab = obj.HistoryTab;
            obj.savePreferences;
            obj.setStatus('历史对话已载入；可以继续提问，或选择版本后点击“使用此版代码”。');
        end

        function viewHistory(obj,index)
            if isempty(index) || index<1 || index>numel(obj.Store.Turns), return; end
            obj.SelectedHistory = index;
            turn = obj.Store.Turns(index);
            obj.HistoryDetail.Value = textLines(sprintf('第 %d 轮 · %s · %s\n\n问题：\n%s\n\n回答：\n%s\n\n代码：\n%s', ...
                index,turn.time,turn.model,turn.question,turn.explanation,turn.replacement));
            obj.updateButtons;
        end

        function useVersion(obj,index)
            if nargin<2, index=obj.SelectedHistory; end
            if obj.IsBusy, error('MatlabAI:Busy','请先结束当前请求。'); end
            if index<1 || index>numel(obj.Store.Turns) || isempty(obj.Store.Turns(index).replacement)
                error('MatlabAI:NoVersion','请选择一个包含代码的历史版本。');
            end
            turn = obj.Store.Turns(index);
            if startsWith(turn.mode,'sim_'), error('MatlabAI:SimHistory','模型历史仅供查看，请重新读取目标模型后生成新方案。'); end
            obj.Store.branch(index);
            obj.invalidatePreview;
            obj.Mode.Value = 'generate'; obj.Scope.Value = 'file'; obj.RequestMode='generate';
            obj.GeneratedText = turn.replacement;
            obj.GeneratedCode.Value = textLines(turn.replacement);
            obj.Answer.Value = textLines(turn.explanation);
            obj.Question.Value = {''};
            obj.runCodeCheck(turn.replacement);
            obj.refreshHistory;
            obj.Tabs.SelectedTab = obj.GeneratedTab;
            obj.ContextLabel.Text = sprintf('从第 %d 轮代码继续；后续对话将另存，编辑器尚未修改。',index);
            obj.updateButtons;
            obj.setStatus('已载入所选版本，可以继续提问、预览插入或新建文档。');
        end

        function compareVersion(obj)
            index = obj.SelectedHistory;
            if index<1, error('MatlabAI:NoVersion','请先选择历史版本。'); end
            previous = '';
            for k=index-1:-1:1
                if ~isempty(obj.Store.Turns(k).replacement), previous=obj.Store.Turns(k).replacement; break; end
            end
            current = obj.Store.Turns(index).replacement;
            % History comparison must never leave an unrelated apply enabled.
            obj.invalidatePreview;
            obj.Before.Value = textLines(previous); obj.After.Value = textLines(current);
            obj.Diff.HTMLSource = ai_diff_html(previous,current);
            obj.Tabs.SelectedTab = obj.Diff.Parent.Parent;
            obj.setStatus('正在比较历史代码版本；编辑器未修改。');
        end

        function chooseChanges(obj,selected)
            if obj.IsBusy || isempty(obj.Transaction) || obj.Transaction.Applied
                error('MatlabAI:NoProposal','当前没有可筛选的修改。');
            end
            selected = logical(selected(:));
            if numel(selected)~=numel(obj.ChangeBlocks), error('MatlabAI:NoSelection','修改选择无效。'); end
            obj.ChangeTable.Data(:,1)=num2cell(selected);
            if ~any(selected)
                obj.ApplyButton.Enable='off';
                obj.After.Value=textLines(obj.Transaction.BaseText);
                obj.Diff.HTMLSource=ai_diff_html(obj.Transaction.BaseText,obj.Transaction.BaseText);
                obj.setStatus('尚未选择修改，请勾选需要接受的修改块。');
                return;
            end
            obj.Transaction.selectChanges(obj.ChangeBlocks,selected);
            obj.After.Value=textLines(obj.Transaction.ProposedText);
            obj.Diff.HTMLSource=ai_diff_html(obj.Transaction.BaseText,obj.Transaction.ProposedText);
            obj.runCodeCheck(obj.Transaction.ProposedText);
            obj.ApplyButton.Enable='on';
            obj.setStatus(sprintf('已选择 %d/%d 处修改；点击应用后才会写入。',sum(selected),numel(selected)));
        end

        function poll(obj)
            if obj.IsLoadingModels, obj.pollModels; end
            if obj.Closing && ~obj.IsBusy && ~obj.IsLoadingModels, delete(obj); return; end
            if ~obj.IsBusy || isempty(obj.Process), return; end
            if ~obj.Process.HasExited, obj.pollProgress; return; end
            try
                if obj.Cancelled
                    if isempty(obj.AbortReason)
                        obj.Answer.Value = {'请求已取消，代码未修改。'};
                        obj.setStatus('已取消。');
                        if strcmp(obj.RequestMode,'help'), obj.HelpAnswer.Value={'查询已取消。本机资料仍可查看。'}; end
                    else
                        obj.fail(MException('MatlabAI:Timeout','%s',obj.AbortReason));
                    end
                else
                    responseFile = fullfile(obj.Job, 'response.json');
                    if ~isfile(responseFile), error('MatlabAI:Worker','后台进程未返回结果，请检查本地配置。'); end
                    response = jsondecode(fileread(responseFile));
                    if ~isfield(response,'request_id') || ~strcmp(response.request_id, obj.RequestID)
                        error('MatlabAI:StaleResponse','响应与当前请求不匹配，已丢弃。');
                    end
                    if ~isfield(response,'ok') || ~islogical(response.ok) || ~isscalar(response.ok)
                        error('MatlabAI:Response','模型响应格式无效。');
                    end
                    if ~response.ok
                        error('MatlabAI:Backend','%s（耗时 %.1f 秒）', response.error,response.elapsed_seconds);
                    end
                    if ~isfield(response,'explanation') || ~isfield(response,'replacement') || ...
                            ~(ischar(response.explanation) || isstring(response.explanation)) || ...
                            ~(ischar(response.replacement) || isstring(response.replacement))
                        error('MatlabAI:Response','模型响应缺少文本字段。');
                    end
                    obj.LastResponse = response;
                    if isfield(response,'stream_chunks'), obj.StreamChunks=response.stream_chunks; end
                    obj.LastError = '';
                    obj.Answer.Value = textLines(response.explanation);
                    if startsWith(obj.RequestMode,'sim_')
                        obj.SimulinkAnswer.Value=textLines(response.explanation);
                        if strcmp(obj.RequestMode,'sim_explain')
                            if ~isempty(response.replacement), error('MatlabAI:SimReadOnly','解释模型不能包含修改。'); end
                            obj.setStatus(sprintf('模型解释完成 · %.1f 秒 · 未修改模型',response.elapsed_seconds));
                            obj.Tabs.SelectedTab=obj.SimulinkTab;
                        else
                            obj.Transaction.propose(response.replacement);
                            obj.PreviewKind='simulink';
                            obj.SimulinkPlan.Data=obj.Transaction.Summary;
                            if strcmp(obj.RequestMode,'sim_function')
                                obj.preparePreview;
                                obj.Tabs.SelectedTab=obj.Diff.Parent.Parent;
                            else
                                obj.Before.Value=textLines(obj.Transaction.BaseText);
                                obj.After.Value=textLines(obj.Transaction.ProposedText);
                                obj.Tabs.SelectedTab=obj.SimulinkTab;
                            end
                            obj.ApplyButton.Text='应用模型修改'; obj.ApplyButton.Enable='on';
                            obj.setStatus(sprintf('模型修改预览已就绪 · %.1f 秒 · 核对后点击应用模型修改',response.elapsed_seconds));
                        end
                    elseif strcmp(obj.RequestMode,'generate')
                        code = char(response.replacement);
                        if isempty(strtrim(code)) || numel(code)>300000 || startsWith(strtrim(code),'```')
                            error('MatlabAI:Response','没有收到完整的 MATLAB 代码。');
                        end
                        obj.GeneratedText = code;
                        obj.GeneratedCode.Value = textLines(code);
                        obj.runCodeCheck(code);
                        obj.Tabs.SelectedTab = obj.GeneratedTab;
                        obj.setStatus(sprintf('代码已生成 · %.1f 秒 · 可插入当前光标处或放入新文档',response.elapsed_seconds));
                    elseif strcmp(obj.RequestMode,'help')
                        if ~isempty(response.replacement), error('MatlabAI:Response','查询帮助不接受代码修改。'); end
                        obj.HelpAnswer.Value=textLines(response.explanation);
                        obj.Tabs.SelectedTab=obj.HelpTab;
                        obj.setStatus(sprintf('查询完成 · %.1f 秒 · 可查看本机资料或打开官方文档',response.elapsed_seconds));
                    elseif strcmp(obj.RequestMode, 'explain')
                        if ~isempty(response.replacement), error('MatlabAI:Response','解释响应包含意外修改，已拒绝。'); end
                        obj.setStatus(sprintf('解释完成 · %.1f 秒 · 代码未修改', response.elapsed_seconds));
                    else
                        obj.Transaction.propose(response.replacement);
                        obj.PreviewKind = 'edit';
                        obj.preparePreview;
                        obj.Tabs.SelectedTab = obj.Diff.Parent.Parent;
                        obj.ApplyButton.Enable = 'on';
                        obj.ApplyButton.Text = '应用修改';
                        obj.setStatus(sprintf('修改预览已就绪 · %.1f 秒 · 点击“应用修改”后才会回写', response.elapsed_seconds));
                    end
                    try
                        obj.Store.add(obj.RequestQuestion,obj.RequestMode,response.model,response);
                        obj.refreshHistory;
                        obj.savePreferences;
                    catch historyError
                        obj.setStatus(['回答已完成；' historyError.message]);
                    end
                end
            catch exception
                obj.fail(exception);
            end
            obj.finishJob;
            if obj.Closing, delete(obj); end
        end

        function delete(obj)
            try, obj.savePreferences; catch, end
            if ~isempty(obj.CatalogProcess)
                try
                    if ~obj.CatalogProcess.HasExited
                        % model_catalog exits its owned app-server on normal completion.
                        obj.CatalogProcess.WaitForExit(20000);
                        if ~obj.CatalogProcess.HasExited, obj.CatalogProcess.Kill; end
                    end
                catch
                end
                obj.finishModelRefresh;
            end
            if obj.IsBusy && isfolder(obj.Job)
                writeUTF8(fullfile(obj.Job,'cancel.flag'), 'cancel');
            end
            if ~isempty(obj.PollTimer) && isvalid(obj.PollTimer)
                stop(obj.PollTimer); delete(obj.PollTimer);
            end
            if ~isempty(obj.WatchdogTimer) && isvalid(obj.WatchdogTimer)
                stop(obj.WatchdogTimer); delete(obj.WatchdogTimer);
            end
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                obj.Figure.CloseRequestFcn = [];
                delete(obj.Figure);
            end
        end
    end

    methods (Access = private)
        function buildSimulinkTab(obj)
            obj.SimulinkTab=uitab(obj.Tabs,'Title','Simulink 模型');
            grid=uigridlayout(obj.SimulinkTab,[4 1]); grid.RowHeight={34,38,'1x','1x'};
            toolbar=uigridlayout(grid,[1 4]); toolbar.Padding=[0 0 0 0]; toolbar.ColumnWidth={65,'1x',120,100};
            uilabel(toolbar,'Text','目标模型');
            obj.SimulinkTarget=uieditfield(toolbar,'text','Placeholder','已打开的模型名称（不带 .slx）', ...
                'ValueChangedFcn',@(~,~) obj.invalidatePreview);
            uibutton(toolbar,'Text','使用当前模型','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.useCurrentSimulink));
            uibutton(toolbar,'Text','读取模型','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.readSimulink));
            uilabel(grid,'Text','选择“解释模型 / 修改模型 / 修改模块代码”。方案经确认后应用；不会保存或启动仿真。', 'WordWrap','on');
            content=uigridlayout(grid,[1 2]); content.Padding=[0 0 0 0];
            obj.SimulinkSnapshot=uitextarea(content,'Editable','off','FontName','Consolas','Value',{'读取后显示发送给模型的结构、参数、连线和函数代码。'});
            obj.SimulinkAnswer=uitextarea(content,'Editable','off','Value',{'例如：解释选中模块的作用；在两模块间插入一个 Gain；修改 MATLAB Function 的计算。'});
            obj.SimulinkPlan=uitable(grid,'Data',cell(0,3),'ColumnName',{'操作','目标','变化 / 新内容'}, ...
                'ColumnEditable',false,'ColumnWidth',{100,200,'auto'},'RowName',[]);
        end

        function useCurrentSimulink(obj)
            if obj.IsBusy, return; end
            system=gcs;
            if isempty(system), error('MatlabAI:SimModel','请先打开并点击目标 Simulink 模型窗口。'); end
            obj.SimulinkTarget.Value=bdroot(system);
            obj.readSimulink;
        end

        function readSimulink(obj)
            if obj.IsBusy, return; end
            if ~startsWith(obj.Mode.Value,'sim_'), obj.Mode.Value='sim_explain'; obj.modeChanged; end
            obj.capture;
        end

        function buildHelpTab(obj)
            obj.HelpTab=uitab(obj.Tabs,'Title','帮助解答与资料');
            grid=uigridlayout(obj.HelpTab,[4 1]); grid.RowHeight={32,'2x',24,'1x'};
            toolbar=uigridlayout(grid,[1 3]); toolbar.Padding=[0 0 0 0]; toolbar.ColumnWidth={'1x',120,140};
            obj.HelpTopic=uidropdown(toolbar,'Items',{'尚未查询'},'ItemsData',{''});
            uibutton(toolbar,'Text','打开函数文档','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.openHelpDoc(false)));
            uibutton(toolbar,'Text','搜索官方文档','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.openHelpDoc(true)));
            obj.HelpAnswer=uitextarea(grid,'Editable','off','FontSize',13, ...
                'Value',{'例如：interp1 和 spline 有什么区别？我装了哪些工具箱？'});
            uilabel(grid,'Text','本次检索的本机资料（即使模型连接失败也可查看）');
            obj.HelpSources=uitextarea(grid,'Editable','off','FontSize',13,'Value',{'选择“查询帮助”，输入问题后发送；也可先点击“查本机资料”。'});
        end

        function showHelpSources(obj)
            c=obj.HelpContext;
            lines={['MATLAB ' c.release ' · ' c.version],c.notice,'','已安装产品（不代表许可证可用）：'};
            for k=1:numel(c.products)
                lines{end+1}=[c.products(k).name '  ' c.products(k).version];
            end
            topics={c.documents.topic};
            if isempty(topics)
                topics={''}; labels={'未命中函数帮助，可搜索官方文档'};
                lines{end+1}='没有命中本机函数帮助；可写出函数英文名以便查询。';
            else
                labels=topics;
                for k=1:numel(c.documents)
                    d=c.documents(k);
                    lines=[lines {'';['[' d.id '] 本机 help ' d.topic];d.text}'];
                end
            end
            obj.HelpTopic.ItemsData={}; obj.HelpTopic.Items=labels; obj.HelpTopic.ItemsData=topics;
            obj.HelpTopic.Value=topics{1};
            obj.HelpSources.Value=textLines(strjoin(lines,newline));
        end

        function openHelpDoc(obj,search)
            if search
                query=char(strjoin(string(obj.Question.Value),newline));
                if isempty(strtrim(query)), error('MatlabAI:Question','请先输入要查询的问题。'); end
                docsearch(query);
            elseif ~isempty(obj.HelpTopic.Value)
                doc(obj.HelpTopic.Value);
            else
                error('MatlabAI:HelpTopic','请先查询函数，或点击“搜索官方文档”。');
            end
        end

        function watchdog(obj)
            if ~obj.IsBusy, return; end
            try
                limit = 60;
                if isfield(obj.Config,'timeout_seconds'), limit=obj.Config.timeout_seconds; end
                if ~obj.Cancelled && toc(obj.RequestStarted)>limit+2
                    obj.AbortReason='请求超过等待上限，已停止后台任务。请重试或切换模型。';
                    obj.cancel;
                end
                if obj.Cancelled && toc(obj.CancelStarted)>5 && ...
                        ~obj.Process.HasExited && isempty(obj.Reaper)
                    % Terminate only this request's owned worker and descendants.
                    info=System.Diagnostics.ProcessStartInfo;
                    info.FileName=fullfile(getenv('WINDIR'),'System32','taskkill.exe');
                    info.Arguments=sprintf('/PID %d /T /F',obj.Process.Id);
                    info.UseShellExecute=false; info.CreateNoWindow=true;
                    obj.Reaper=System.Diagnostics.Process.Start(info);
                end
                % A separate timer also recovers when the ordinary poll timer stops.
                if strcmp(obj.PollTimer.Running,'off') || obj.Process.HasExited
                    obj.poll;
                end
            catch exception
                obj.LastError=exception.message;
            end
        end

        function preparePreview(obj)
            transaction=obj.Transaction;
            obj.Before.Value=textLines(transaction.BaseText);
            obj.After.Value=textLines(transaction.ProposedText);
            obj.Diff.HTMLSource=ai_diff_html(transaction.BaseText,transaction.ProposedText);
            obj.ChangeBlocks=ai_change_blocks(transaction.BaseText,transaction.ProposedText);
            data=cell(numel(obj.ChangeBlocks),4);
            for k=1:numel(obj.ChangeBlocks)
                b=obj.ChangeBlocks(k); data(k,:)={true,b.line,b.oldCount,b.newCount};
            end
            obj.ChangeTable.Data=data; obj.ChangeTable.Enable='on';
            obj.runCodeCheck(transaction.ProposedText);
        end

        function runCodeCheck(obj,code)
            try
                obj.CheckReport=ai_check_code(code);
                obj.CheckView.Value=obj.CheckReport.lines;
                obj.CheckTab.Title=sprintf('代码检查 (%d)',obj.CheckReport.count);
            catch exception
                obj.CheckReport=struct('count',NaN,'messages',[],'error',exception.message);
                obj.CheckView.Value={'静态检查未完成；代码尚未运行。',exception.message};
                obj.CheckTab.Title='代码检查（未完成）';
            end
        end

        function pollProgress(obj)
            if obj.Cancelled, return; end
            file=fullfile(obj.Job,'progress.json');
            if isfile(file)
                try
                    progress=jsondecode(fileread(file));
                    if ~strcmp(progress.request_id,obj.RequestID), return; end
                    obj.LastPhase=progress.phase;
                    if progress.chunks~=obj.LastProgressChunks
                        obj.LastProgressChunks=progress.chunks;
                        obj.StreamChunks=progress.chunks;
                        if isfield(progress,'explanation') && ~isempty(progress.explanation)
                            obj.Answer.Value=textLines(progress.explanation);
                            if strcmp(obj.RequestMode,'help'), obj.HelpAnswer.Value=textLines(progress.explanation); end
                            if startsWith(obj.RequestMode,'sim_'), obj.SimulinkAnswer.Value=textLines(progress.explanation); end
                        end
                        if ~strcmp(obj.RequestMode,'help') && ~startsWith(obj.RequestMode,'sim_') && isfield(progress,'replacement') && ~isempty(progress.replacement)
                            obj.GeneratedCode.Value=textLines(progress.replacement);
                            obj.Tabs.SelectedTab=obj.GeneratedTab;
                        end
                    end
                catch
                    % A snapshot may be replaced while this timer reads it.
                end
            end
            switch obj.LastPhase
                case 'connecting', phase='正在连接模型';
                case 'generating', phase='正在生成';
                case 'streaming', phase='正在接收回答';
                otherwise, phase='正在校验完整结果';
            end
            obj.setStatus(sprintf('%s · %.0f 秒 · 快速响应 · 携带 %d 轮对话 · 生成中的代码暂不可插入', ...
                phase,toc(obj.RequestStarted),obj.RequestHistoryCount));
        end

        function refreshHistory(obj)
            entries=obj.Store.list;
            labels={'当前对话'}; ids={''};
            for k=1:numel(entries)
                labels{end+1}=entries(k).label; ids{end+1}=entries(k).id;
            end
            obj.HistoryPicker.ItemsData={}; obj.HistoryPicker.Items=labels; obj.HistoryPicker.ItemsData=ids;
            if ismember(obj.Store.ID,ids), obj.HistoryPicker.Value=obj.Store.ID;
            else, obj.HistoryPicker.Value=''; end
            turns=obj.Store.Turns;
            data=cell(numel(turns),4);
            names=struct('generate','需求生成','help','查询帮助','edit','修改','explain','解释','complete','续写', ...
                'sim_explain','解释模型','sim_edit','修改模型','sim_function','修改模块代码');
            for k=1:numel(turns)
                question=regexprep(turns(k).question,'\s+',' ');
                data(k,:)={turns(k).time,names.(turns(k).mode),question,turns(k).model};
            end
            obj.HistoryTable.Data=data;
            obj.SelectedHistory=numel(turns);
            if isempty(turns), obj.HistoryDetail.Value={'本地对话将在这里显示。'};
            else, obj.viewHistory(numel(turns)); end
            obj.ConversationLabel.Text=sprintf('%d 轮对话 · 本地保存 · Ctrl+Enter 发送',numel(turns));
            obj.updateButtons;
        end

        function selectHistory(obj)
            if ~isempty(obj.HistoryPicker.Value), obj.loadConversation(obj.HistoryPicker.Value); end
        end

        function selectHistoryRow(obj,event)
            if ~isempty(event.Indices), obj.viewHistory(event.Indices(1,1)); end
        end

        function keyPressed(obj,event)
            if strcmp(event.Key,'return') && any(ismember(event.Modifier,{'control','command'})) && ~obj.IsBusy
                obj.invoke(@() obj.ask);
            end
        end

        function changeFont(obj)
            size=str2double(obj.FontPicker.Value);
            for widget={obj.Question,obj.Answer,obj.GeneratedCode,obj.Before,obj.After,obj.CheckView,obj.HistoryDetail,obj.HelpAnswer,obj.HelpSources}
                widget{1}.FontSize=size;
            end
            obj.savePreferences;
        end

        function savePreferences(obj)
            if isempty(obj.Store) || isempty(obj.Store.Folder) || isempty(obj.Figure) || ~isvalid(obj.Figure), return; end
            preferences=struct('position',obj.Figure.Position,'font',obj.FontPicker.Value, ...
                'session',obj.Store.ID,'draft',char(strjoin(string(obj.Question.Value),newline)), ...
                'continue',obj.ContinueCheck.Value);
            target=fullfile(obj.Store.Folder,'preferences.json');
            temporary=[target '.' char(java.util.UUID.randomUUID) '.tmp'];
            writeUTF8(temporary,jsonencode(preferences));
            [ok,~]=movefile(temporary,target,'f');
            if ~ok && isfile(temporary), delete(temporary); end
        end

        function loadPreferences(obj)
            if isempty(obj.Store.Folder), return; end
            file=fullfile(obj.Store.Folder,'preferences.json');
            if ~isfile(file), return; end
            try
                preferences=jsondecode(fileread(file));
                if isfield(preferences,'session') && isfile(fullfile(obj.Store.Folder,[preferences.session '.json']))
                    obj.Store.load(preferences.session); obj.refreshHistory;
                    if ~isempty(obj.Store.Turns)
                        obj.GeneratedCode.Value=textLines(obj.Store.Turns(end).replacement);
                        obj.Answer.Value=textLines(obj.Store.Turns(end).explanation);
                    end
                end
                if isfield(preferences,'draft') && ischar(preferences.draft), obj.Question.Value=textLines(preferences.draft); end
                if isfield(preferences,'continue') && islogical(preferences.continue), obj.ContinueCheck.Value=preferences.continue; end
                if isfield(preferences,'position') && numel(preferences.position)==4 && all(isfinite(preferences.position))
                    position=preferences.position(:)'; screens=get(groot,'MonitorPositions');
                    if any(position(1)>=screens(:,1) & position(1)<screens(:,1)+screens(:,3) & ...
                            position(2)>=screens(:,2) & position(2)<screens(:,2)+screens(:,4)) && all(position(3:4)>=[850,650])
                        obj.Figure.Position=position;
                    end
                end
                if isfield(preferences,'font') && ismember(preferences.font,obj.FontPicker.Items)
                    obj.FontPicker.Value=preferences.font; obj.changeFont;
                end
            catch
                obj.setStatus('部分历史或界面设置无法读取，原文件已保留。');
            end
        end

        function buildUI(obj, visibility)
            obj.Figure = uifigure('Name','MATLAB AI 助手', 'Position',[100 70 1120 830], ...
                'Color',[0.96 0.97 0.99], 'Visible',visibility, 'CloseRequestFcn',@(~,~) obj.requestClose, ...
                'WindowKeyPressFcn',@(~,event) obj.keyPressed(event));
            layout = uigridlayout(obj.Figure,[9 1]);
            layout.RowHeight = {36,32,34,40,90,38,100,'1x',28};
            layout.Padding = [20 14 20 14];
            layout.RowSpacing = 8;
            title = uilabel(layout,'Text','MATLAB AI  /  代码助手', 'FontSize',22, 'FontWeight','bold', 'FontColor',[0.12 0.19 0.30]);
            title.Layout.Row = 1;
            conversation = uigridlayout(layout,[1 6]); conversation.Layout.Row=2;
            conversation.Padding=[0 0 0 0]; conversation.ColumnWidth={145,90,115,'1x',35,65};
            obj.ContinueCheck = uicheckbox(conversation,'Text','继续当前对话','Value',true, ...
                'Tooltip','发送最近最多 6 轮完整问答；超出长度上限时保留最近轮次。');
            obj.NewConversationButton = uibutton(conversation,'Text','新对话','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.newConversation));
            obj.RepairButton = uibutton(conversation,'Text','按报错修正', ...
                'Tooltip','在问题框粘贴报错或描述问题，再点击此按钮。','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.repairFromError));
            obj.ConversationLabel = uilabel(conversation,'Text','新对话 · 本地保存', 'FontColor',[0.38 0.43 0.52]);
            uilabel(conversation,'Text','字号');
            obj.FontPicker = uidropdown(conversation,'Items',{'11','13','15','17','20'},'Value','13', ...
                'ValueChangedFcn',@(~,~) obj.changeFont);
            controls = uigridlayout(layout,[1 8]);
            controls.Layout.Row = 3;
            controls.Padding = [0 0 0 0];
            controls.ColumnWidth = {40,115,40,145,40,'1x',90,120};
            uilabel(controls,'Text','操作');
            obj.Mode = uidropdown(controls,'Items',{'需求生成','查询帮助','解释','修改','续写','解释模型','修改模型','修改模块代码'}, ...
                'ItemsData',{'generate','help','explain','edit','complete','sim_explain','sim_edit','sim_function'}, 'Value','generate', ...
                'ValueChangedFcn',@(~,~) obj.modeChanged);
            uilabel(controls,'Text','范围');
            obj.Scope = uidropdown(controls,'Items',{'当前文件','选中代码','光标处插入'}, ...
                'ItemsData',{'file','selection','cursor'}, 'Value','file', ...
                'ValueChangedFcn',@(~,~) obj.invalidatePreview);
            uilabel(controls,'Text','模型');
            initial = obj.Config.model;
            if isempty(initial)
                labels = {'尚未读取到模型'}; values = {''};
            else
                labels = {[initial '（当前配置）']}; values = {initial};
            end
            obj.Model = uidropdown(controls,'Items',labels,'ItemsData',values,'Value',initial, ...
                'Editable','off','ValueChangedFcn',@(~,~) obj.invoke(@() obj.modelChanged));
            obj.ModelRefreshButton = uibutton(controls,'Text','刷新模型', ...
                'ButtonPushedFcn',@(~,~) obj.refreshModels);
            obj.CaptureButton = uibutton(controls,'Text','读取当前代码','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.capture));
            obj.ContextLabel = uilabel(layout,'Text','需求生成：无需先打开文件，可以连续追问；对话保存在本机。', ...
                'WordWrap','on','FontColor',[0.32 0.40 0.50]);
            obj.ContextLabel.Layout.Row = 4;
            obj.Question = uitextarea(layout,'Placeholder','例如：生成读取 Excel 并绘制折线图的 MATLAB 代码。也可选择解释、修改或续写已有代码。', ...
                'FontSize',14,'ValueChangedFcn',@(~,~) obj.savePreferences);
            obj.Question.Layout.Row = 5;
            buttons = uigridlayout(layout,[1 7]); buttons.Layout.Row = 6;
            buttons.Padding = [0 0 0 0]; buttons.ColumnWidth = {110,70,'1x',105,105,105,140};
            obj.SendButton = uibutton(buttons,'Text','发送问题','BackgroundColor',[0.13 0.35 0.66], ...
                'FontColor',[1 1 1],'ButtonPushedFcn',@(~,~) obj.invoke(@() obj.ask));
            obj.CancelButton = uibutton(buttons,'Text','取消','Enable','off','ButtonPushedFcn',@(~,~) obj.cancel);
            obj.SettingsButton=uibutton(buttons,'Text','后端与等待设置', ...
                'ButtonPushedFcn',@(~,~) obj.openSettings);
            obj.InsertButton = uibutton(buttons,'Text','预览光标插入','Enable','off','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.insertGenerated(false)));
            obj.NewDocumentButton = uibutton(buttons,'Text','新建代码文档','Enable','off','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.insertGenerated(true)));
            obj.ApplyButton = uibutton(buttons,'Text','应用修改','Enable','off','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.apply));
            obj.RestoreButton = uibutton(buttons,'Text','恢复上次修改','Enable','off','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.restore));
            obj.Answer = uitextarea(layout,'Editable','off','Value',{'回答会显示在这里。'},'FontSize',13);
            obj.Answer.Layout.Row = 7;
            obj.Tabs = uitabgroup(layout); obj.Tabs.Layout.Row = 8;
            obj.GeneratedTab = uitab(obj.Tabs,'Title','生成的代码');
            generatedGrid = uigridlayout(obj.GeneratedTab,[1 1]);
            generatedGrid.Padding = [8 8 8 8];
            obj.GeneratedCode = uitextarea(generatedGrid,'Editable','off','FontName','Consolas','FontSize',13);
            obj.buildHelpTab;
            obj.buildSimulinkTab;
            obj.buildSettingsTab;
            diffTab = uitab(obj.Tabs,'Title','逐行差异');
            diffGrid = uigridlayout(diffTab,[2 1]); diffGrid.Padding = [0 0 0 0];
            diffGrid.RowHeight = {90,'1x'};
            obj.ChangeTable = uitable(diffGrid,'Data',cell(0,4), ...
                'ColumnName',{'接受','起始行','删除行','新增行'},'ColumnEditable',[true,false,false,false], ...
                'ColumnWidth',{60,100,100,100},'RowName',[], ...
                'CellEditCallback',@(~,~) obj.invoke(@() obj.chooseChanges(cell2mat(obj.ChangeTable.Data(:,1)))));
            obj.Diff = uihtml(diffGrid,'HTMLSource','<html><body style="font-family:sans-serif;color:#64748b;padding:20px">生成修改后，绿色表示新增，红色表示删除。</body></html>');
            textTab = uitab(obj.Tabs,'Title','修改前 / 修改后');
            pair = uigridlayout(textTab,[2 2]); pair.RowHeight = {22,'1x'};
            l = uilabel(pair,'Text','修改前 / 已读取上下文'); l.Layout.Row = 1; l.Layout.Column = 1;
            l = uilabel(pair,'Text','修改后的完整文档'); l.Layout.Row = 1; l.Layout.Column = 2;
            obj.Before = uitextarea(pair,'Editable','off','FontName','Consolas','FontSize',12);
            obj.Before.Layout.Row = 2; obj.Before.Layout.Column = 1;
            obj.After = uitextarea(pair,'Editable','off','FontName','Consolas','FontSize',12);
            obj.After.Layout.Row = 2; obj.After.Layout.Column = 2;
            obj.CheckTab = uitab(obj.Tabs,'Title','代码检查');
            checkGrid = uigridlayout(obj.CheckTab,[1 1]);
            obj.CheckView = uitextarea(checkGrid,'Editable','off','FontSize',13, ...
                'Value',{'生成后自动进行静态检查，不运行代码。'});
            obj.HistoryTab = uitab(obj.Tabs,'Title','对话与版本');
            historyGrid = uigridlayout(obj.HistoryTab,[4 1]); historyGrid.RowHeight={32,105,32,'1x'};
            historyTools=uigridlayout(historyGrid,[1 2]); historyTools.Padding=[0 0 0 0]; historyTools.ColumnWidth={'1x',90};
            obj.HistoryPicker=uidropdown(historyTools,'Items',{'当前对话'},'ItemsData',{''}, ...
                'ValueChangedFcn',@(~,~) obj.invoke(@() obj.selectHistory));
            uibutton(historyTools,'Text','刷新历史','ButtonPushedFcn',@(~,~) obj.refreshHistory);
            obj.HistoryTable=uitable(historyGrid,'Data',cell(0,4),'ColumnName',{'时间','操作','问题','模型'}, ...
                'ColumnWidth',{145,70,'auto',130},'RowName',[], ...
                'CellSelectionCallback',@(~,event) obj.selectHistoryRow(event));
            historyButtons=uigridlayout(historyGrid,[1 3]); historyButtons.Padding=[0 0 0 0]; historyButtons.ColumnWidth={130,130,'1x'};
            obj.ReuseButton=uibutton(historyButtons,'Text','使用此版代码','Enable','off','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.useVersion));
            obj.CompareButton=uibutton(historyButtons,'Text','比较上一版','Enable','off','ButtonPushedFcn',@(~,~) obj.invoke(@() obj.compareVersion));
            uilabel(historyButtons,'Text','选择一轮查看；使用旧版本后继续提问会另存为新对话。');
            obj.HistoryDetail=uitextarea(historyGrid,'Editable','off','FontName','Consolas','FontSize',13);
            obj.Status = uilabel(layout,'Text','','FontColor',[0.16 0.31 0.48]);
            obj.Status.Layout.Row = 9;
        end

        function modeChanged(obj)
            previousScope=obj.Scope.Value;
            obj.Scope.ItemsData={};
            if startsWith(obj.Mode.Value,'sim_')
                obj.Scope.Items={'当前模型','选中模块及连线'}; obj.Scope.ItemsData={'file','selection'};
                if strcmp(previousScope,'selection'), obj.Scope.Value='selection'; else, obj.Scope.Value='file'; end
                if strcmp(obj.Mode.Value,'sim_function'), obj.Scope.Value='selection'; end
            else
                obj.Scope.Items={'当前文件','选中代码','光标处插入'}; obj.Scope.ItemsData={'file','selection','cursor'};
                obj.Scope.Value=previousScope;
            end
            if strcmp(obj.Mode.Value,'complete'), obj.Scope.Value = 'cursor';
            elseif strcmp(obj.Scope.Value,'cursor'), obj.Scope.Value = 'file'; end
            obj.invalidatePreview;
            obj.updateButtons;
            if strcmp(obj.Mode.Value,'generate')
                obj.Tabs.SelectedTab = obj.GeneratedTab;
                obj.ContextLabel.Text = '需求生成：发送需求及启用的最近对话；生成后可预览插入或新建文档。';
            elseif strcmp(obj.Mode.Value,'help')
                obj.Tabs.SelectedTab=obj.HelpTab;
                obj.ContextLabel.Text='查询函数、概念及工具箱；发送本机帮助及安装清单，继续对话仅携带帮助问答。';
            elseif startsWith(obj.Mode.Value,'sim_')
                obj.Tabs.SelectedTab=obj.SimulinkTab;
                obj.ContextLabel.Text='先在 Simulink 页指定模型；选择模块或信号线后，可按选中范围提问。';
            end
        end

        function invalidatePreview(obj)
            obj.Transaction = [];
            obj.GeneratedText = '';
            obj.GeneratedConsumed = false;
            obj.ApplyButton.Enable = 'off';
            obj.InsertButton.Enable = 'off';
            obj.NewDocumentButton.Enable = 'off';
            obj.PreviewKind = '';
            obj.ChangeBlocks = struct([]);
            if ~isempty(obj.ChangeTable), obj.ChangeTable.Data=cell(0,4); end
            obj.ApplyButton.Text='应用修改';
            obj.setStatus('操作或范围已变化，请重新读取代码或发送问题。');
        end

        function showContext(obj)
            t = obj.Transaction;
            if strcmp(t.Scope,'selection'), range = sprintf('选中代码 [%d:%d → %d:%d]',t.Selection);
            elseif strcmp(t.Scope,'cursor'), range = '发送当前文件；仅在光标处插入';
            else, range = '当前文件全文'; end
            obj.ContextLabel.Text = sprintf('目标：%s\n发送：%s · %d 字符 · 包含未保存内容', ...
                t.Filename, range, numel(t.Context));
            obj.Before.Value = textLines(t.Context);
        end

        function updateButtons(obj)
            if obj.IsBusy, available = 'off'; else, available = 'on'; end
            if ~isempty(obj.SettingsSaveButton)
                obj.SettingsSaveButton.Enable=available;
                if obj.IsLoadingModels, obj.SettingsSaveButton.Enable='off'; end
            end
            obj.SendButton.Enable = available;
            obj.CaptureButton.Enable = available;
            obj.CaptureButton.Text = '读取当前代码';
            obj.Mode.Enable = available;
            obj.Scope.Enable = available;
            obj.Model.Enable = available;
            obj.ModelRefreshButton.Enable = available;
            if ~isempty(obj.SimulinkTarget), obj.SimulinkTarget.Enable=available; end
            obj.ContinueCheck.Enable=available;
            obj.NewConversationButton.Enable=available;
            obj.RepairButton.Enable=available;
            obj.HistoryPicker.Enable=available;
            if obj.SelectedHistory>0 && ~obj.IsBusy && ~isempty(obj.Store.Turns(obj.SelectedHistory).replacement) && ...
                    ~startsWith(obj.Store.Turns(obj.SelectedHistory).mode,'sim_')
                obj.ReuseButton.Enable='on'; obj.CompareButton.Enable='on';
            else
                obj.ReuseButton.Enable='off'; obj.CompareButton.Enable='off';
            end
            if strcmp(obj.Mode.Value,'generate')
                obj.Scope.Enable = 'off';
                obj.CaptureButton.Enable = 'off';
            elseif strcmp(obj.Mode.Value,'help')
                obj.Scope.Enable='off'; obj.RepairButton.Enable='off';
                obj.CaptureButton.Text='查本机资料';
            elseif startsWith(obj.Mode.Value,'sim_')
                obj.CaptureButton.Text='读取目标模型';
                if strcmp(obj.Mode.Value,'sim_function'), obj.Scope.Enable='off'; end
            end
            canInsert = ~strcmp(obj.Mode.Value,'help') && ~obj.IsBusy && ~isempty(obj.GeneratedText) && ~obj.GeneratedConsumed;
            if canInsert, insertState = 'on'; else, insertState = 'off'; end
            obj.InsertButton.Enable = insertState;
            obj.NewDocumentButton.Enable = insertState;
            if obj.IsLoadingModels
                obj.Model.Enable = 'off';
                obj.ModelRefreshButton.Enable = 'off';
                obj.SendButton.Enable = 'off';
            elseif isempty(obj.Model.Value)
                obj.Model.Enable = 'off';
                obj.SendButton.Enable = 'off';
            end
            if obj.IsBusy
                obj.CancelButton.Enable = 'on';
                obj.RestoreButton.Enable = 'off';
                obj.ApplyButton.Enable = 'off';
            else
                obj.CancelButton.Enable = 'off';
                hasProposal=~isempty(obj.Transaction) && obj.Transaction.Prepared && ...
                    ~obj.Transaction.Applied && ~obj.Transaction.Restored;
                if hasProposal
                    obj.ChangeTable.Enable='on';
                    if isempty(obj.ChangeBlocks) || any(cell2mat(obj.ChangeTable.Data(:,1)))
                        obj.ApplyButton.Enable='on';
                    else
                        obj.ApplyButton.Enable='off';
                    end
                else
                    obj.ApplyButton.Enable='off'; obj.ChangeTable.Enable='off';
                end
                if ~isempty(obj.LastApplied) && ~obj.LastApplied.Restored
                    obj.RestoreButton.Enable = 'on';
                end
            end
        end

        function finishJob(obj)
            if ~obj.IsLoadingModels && ~isempty(obj.PollTimer) && isvalid(obj.PollTimer), stop(obj.PollTimer); end
            obj.IsBusy = false;
            if ~isempty(obj.Reaper), obj.Reaper.Dispose; obj.Reaper=[]; end
            if ~isempty(obj.Process), obj.Process.Dispose; obj.Process = []; end
            if ~isempty(obj.Job) && isfolder(obj.Job)
                % This exact UUID folder is created and owned by this instance.
                rmdir(obj.Job,'s');
            end
            obj.Job = '';
            obj.updateButtons;
        end

        function invoke(obj, callback)
            try, callback(); catch exception, obj.fail(exception); end
        end

        function fail(obj, exception)
            obj.LastError = exception.message;
            obj.ApplyButton.Enable = 'off';
            obj.Answer.Value = textLines(exception.message);
            if strcmp(obj.RequestMode,'help') && ~isempty(obj.HelpAnswer)
                obj.HelpAnswer.Value=textLines([exception.message newline '已查到的本机资料仍保留在下方，可直接查看或打开官方文档。']);
            end
            if startsWith(obj.RequestMode,'sim_') && ~isempty(obj.SimulinkAnswer)
                obj.SimulinkAnswer.Value=textLines(exception.message);
            end
            obj.setStatus('操作未完成：' + string(exception.message));
        end

        function setStatus(obj, message)
            obj.Status.Text = char(message);
        end

        function pollError(obj)
            if obj.IsLoadingModels
                obj.Model.Tooltip = '模型列表读取失败，可以点击刷新重试。';
            end
            obj.LastError = '后台状态检查失败，正在自动结束请求，可随后重试。';
            if obj.IsBusy, obj.cancel; end
            obj.setStatus(obj.LastError);
        end

        function requestClose(obj)
            if obj.IsBusy
                obj.Closing = true;
                obj.cancel;
                obj.Figure.Visible = 'off';
            elseif obj.IsLoadingModels
                obj.Closing = true;
                obj.Figure.Visible = 'off';
            else
                delete(obj);
            end
        end

        function pollModels(obj)
            if isempty(obj.CatalogProcess) || ~obj.CatalogProcess.HasExited, return; end
            try
                response = jsondecode(fileread(fullfile(obj.CatalogJob,'models.json')));
                if ~response.ok || isempty(response.models)
                    error('MatlabAI:Models','%s',response.warning);
                end
                previous = obj.Model.Value;
                obj.ModelCatalog = response.models;
                ids = {response.models.id};
                labels = ids;
                for k=1:numel(ids)
                    if strcmp(response.models(k).source,'config')
                        labels{k} = [ids{k} '（本地配置）'];
                    elseif strcmp(response.models(k).source,'cache')
                        labels{k} = [ids{k} '（缓存）'];
                    end
                end
                obj.Model.ItemsData = {};
                obj.Model.Items = labels;
                obj.Model.ItemsData = ids;
                if ismember(previous,ids), obj.Model.Value = previous;
                else, obj.Model.Value = response.selected; end
                obj.ModelSource = response.source;
                obj.Model.Tooltip = sprintf('当前 Agent：%s；模型调用取决于后端权限。\n%s',obj.Config.backend,response.warning);
                if isempty(response.warning)
                    obj.setStatus(sprintf('已读取 %d 个模型，可直接下拉切换。',numel(ids)));
                else
                    obj.setStatus(sprintf('已读取 %d 个选项。%s',numel(ids),response.warning));
                end
            catch exception
                % Retain the last known list or explicit local model on failure.
                obj.Model.Tooltip = ['模型列表刷新失败：' exception.message];
                obj.setStatus(obj.Model.Tooltip);
            end
            obj.finishModelRefresh;
        end

        function finishModelRefresh(obj)
            obj.IsLoadingModels = false;
            if ~isempty(obj.CatalogProcess), obj.CatalogProcess.Dispose; obj.CatalogProcess = []; end
            if ~isempty(obj.CatalogJob) && isfolder(obj.CatalogJob)
                % Only this instance's UUID directory, which contains catalog metadata.
                rmdir(obj.CatalogJob,'s');
            end
            obj.CatalogJob = '';
            obj.ModelRefreshButton.Text = '刷新模型';
            if ~obj.IsBusy && ~isempty(obj.PollTimer) && isvalid(obj.PollTimer), stop(obj.PollTimer); end
            obj.updateButtons;
        end
    end
end

function result = textLines(text)
result = cellstr(splitlines(string(text)));
if isempty(result), result = {''}; end
end

function writeUTF8(path, text)
fid = fopen(path,'w','n','UTF-8');
if fid < 0, error('MatlabAI:LocalFile','无法写入本地请求文件。'); end
cleanup = onCleanup(@() fclose(fid));
fwrite(fid, unicode2native(text,'UTF-8'), 'uint8');
end
