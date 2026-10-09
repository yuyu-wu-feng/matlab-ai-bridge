classdef AISimulinkTransaction < handle
    % Validated operations and an inverse journal, bound to one loaded model.
    properties (SetAccess=private)
        Model
        Mode
        Scope
        Context
        BaseText
        ProposedText=''
        Prepared=false
        Applied=false
        Restored=false
        Operations={}
        Summary=cell(0,3)
        Selected={}
        FunctionPath=''
    end
    properties (Access=private)
        ModelHandle
        BaseState
        AfterState=''
        DirtyBefore
        FileName
        FileBytes=[]
        Journal={}
        Allowed={}
    end
    methods
        function obj=AISimulinkTransaction(model,mode,scope)
            if nargin<3, scope='file'; end
            assert(ismember(mode,{'sim_explain','sim_edit','sim_function'}),'MatlabAI:SimMode','无效的模型操作。');
            assert(isvarname(model) && bdIsLoaded(model),'MatlabAI:SimModel','请先打开模型，再指定目标模型名称（不带路径或扩展名）。');
            obj.Model=char(model); obj.Mode=mode; obj.Scope=scope;
            obj.ModelHandle=get_param(model,'Handle');
            obj.FileName=get_param(model,'FileName'); obj.FileBytes=readFile(obj.FileName);
            obj.DirtyBefore=get_param(model,'Dirty');
            state=ai_simulink_snapshot(model); obj.BaseState=jsonencode(state);
            selected=find_system(model,'LookUnderMasks','none','FollowLinks','off','Type','Block','Selected','on');
            obj.Selected=cellfun(@(p) p(numel(model)+2:end),selected,'UniformOutput',false);
            selectedLines=find_system(model,'FindAll','on','LookUnderMasks','none','FollowLinks','off','Type','line','Selected','on');
            selectedEdges=struct('source',{},'target',{});
            for k=1:numel(selectedLines)
                src=get_param(selectedLines(k),'SrcBlockHandle'); dst=get_param(selectedLines(k),'DstBlockHandle');
                if src<0, continue; end
                for j=1:numel(dst)
                    if dst(j)<0, continue; end
                    a=getfullname(src); b=getfullname(dst(j));
                    a=a(numel(model)+2:end); b=b(numel(model)+2:end);
                    selectedEdges(end+1)=struct('source',a,'target',b);
                    if ~strcmp(mode,'sim_function'), obj.Selected=unique([obj.Selected(:)' {a,b}],'stable'); end
                end
            end
            obj.Allowed={state.blocks.path};
            if strcmp(scope,'selection') || strcmp(mode,'sim_function')
                assert(~isempty(obj.Selected),'MatlabAI:SimSelection','请先在目标模型中选择模块。');
                obj.Allowed=obj.Selected;
            end
            context=state;
            if strcmp(scope,'selection')
                e=state.connections;
                keep=ismember({e.source},obj.Selected) | ismember({e.target},obj.Selected);
                context.connections=e(keep);
                neighbors=unique([obj.Selected {e(keep).source} {e(keep).target}]);
                context.blocks=state.blocks(ismember({state.blocks.path},neighbors));
            end
            context.selected=obj.Selected; context.editable_paths=obj.Allowed;
            context.selected_lines=selectedEdges;
            context=rmfield(context,'callbacks');
            context.blocks=rmfield(context.blocks,{'callbacks','identity'});
            context.add_kinds=fieldnames(ai_simulink_catalog);
            context.set_parameters=allowedParameters;
            obj.Context=jsonencode(context,PrettyPrint=true);
            obj.BaseText=jsonencode(state,PrettyPrint=true);
            if strcmp(mode,'sim_function')
                assert(numel(obj.Selected)==1,'MatlabAI:SimSelection','请选择一个 MATLAB Function 模块。');
                obj.FunctionPath=obj.Selected{1};
                block=state.blocks(strcmp({state.blocks.path},obj.FunctionPath));
                assert(~isempty(block.script),'MatlabAI:SimFunction','选中模块不是 MATLAB Function。');
                obj.BaseText=block.script;
            end
        end

        function propose(obj,replacement)
            assert(~strcmp(obj.Mode,'sim_explain'),'MatlabAI:SimReadOnly','解释模型不能产生修改。');
            assert(~obj.Applied && ~obj.Restored,'MatlabAI:AlreadyApplied','请重新读取模型后提问。');
            if strcmp(obj.Mode,'sim_function')
                assert(ischar(replacement) && startsWith(strtrim(replacement),'function'),'MatlabAI:SimFunction','必须返回完整的 MATLAB 函数。');
                obj.Operations={struct('op','function','path',obj.FunctionPath,'code',replacement)};
                obj.ProposedText=replacement;
            else
                try
                    plan=jsondecode(replacement);
                    assert(isscalar(plan) && isequal(fieldnames(plan),{'operations'}));
                    obj.Operations=asCells(plan.operations);
                catch
                    error('MatlabAI:SimPlan','模型操作清单格式无效，未修改模型。');
                end
                obj.ProposedText=jsonencode(plan,PrettyPrint=true);
            end
            assert(~isempty(obj.Operations) && numel(obj.Operations)<=40,'MatlabAI:SimPlan','每次需要 1–40 个模型操作。');
            obj.validatePlan;
            obj.Prepared=true;
        end

        function selectChanges(obj,blocks,selected)
            assert(strcmp(obj.Mode,'sim_function'),'MatlabAI:SimPlan','模型操作作为整体应用。');
            proposed=obj.BaseText;
            for k=numel(blocks):-1:1
                if selected(k)
                    b=blocks(k); proposed=[proposed(1:b.start-1) b.replacement proposed(b.stop:end)];
                end
            end
            obj.propose(proposed);
        end

        function apply(obj)
            assert(obj.Prepared && ~obj.Applied && ~obj.Restored,'MatlabAI:NoProposal','没有可应用的模型修改。');
            obj.checkUnchanged(obj.BaseState); obj.validatePlan;
            obj.Journal={};
            try
                for k=1:numel(obj.Operations), obj.execute(obj.Operations{k}); end
                obj.AfterState=jsonencode(ai_simulink_snapshot(obj.Model));
                obj.Applied=true;
            catch exception
                try
                    obj.undoJournal;
                    set_param(obj.Model,'Dirty',obj.DirtyBefore);
                catch rollbackError
                    obj.Applied=true;
                    obj.AfterState=jsonencode(ai_simulink_snapshot(obj.Model));
                    error('MatlabAI:SimRollback','应用失败：%s；恢复尚未完成：%s。请保留窗口并点击恢复。',exception.message,rollbackError.message);
                end
                rethrow(exception);
            end
        end

        function restore(obj)
            assert(obj.Applied && ~obj.Restored,'MatlabAI:NoRestore','没有可恢复的模型修改。');
            obj.checkUnchanged(obj.AfterState);
            try
                obj.undoJournal;
            catch exception
                obj.AfterState=jsonencode(ai_simulink_snapshot(obj.Model));
                rethrow(exception);
            end
            set_param(obj.Model,'Dirty',obj.DirtyBefore);
            obj.Restored=true;
        end

        function checkUnchanged(obj,expected)
            assert(bdIsLoaded(obj.Model) && get_param(obj.Model,'Handle')==obj.ModelHandle,'MatlabAI:SimClosed','原模型已关闭或重新打开，请重新提问。');
            assert(strcmp(get_param(obj.Model,'SimulationStatus'),'stopped'),'MatlabAI:SimRunning','请先停止仿真再修改模型。');
            assert(strcmp(get_param(obj.Model,'FileName'),obj.FileName) && isequal(readFile(obj.FileName),obj.FileBytes),'MatlabAI:DiskConflict','模型已另存或磁盘文件变化，请重新读取。');
            assert(strcmp(jsonencode(ai_simulink_snapshot(obj.Model)),expected),'MatlabAI:Conflict','模型结构、参数或代码已变化，已阻止覆盖，请重新提问。');
        end
    end
    methods (Access=private)
        function validatePlan(obj)
            state=jsondecode(obj.BaseState);
            if isempty(state.blocks), known={}; else, known={state.blocks.path}; end
            added={};
            obj.Summary=cell(0,3); catalog=ai_simulink_catalog;
            for k=1:numel(obj.Operations)
                op=obj.Operations{k}; assert(isstruct(op) && isscalar(op) && isfield(op,'op'),'MatlabAI:SimPlan','操作格式无效。');
                switch op.op
                    case 'add'
                        exactFields(op,{'op','path','kind','position'}); validPath(op.path);
                        assert(~ismember(op.path,known) && isfield(catalog,op.kind),'MatlabAI:SimPlan','新增模块重名或类型不支持。');
                        parent=parentOf(op.path);
                        assert(isempty(parent) || ismember(parent,known),'MatlabAI:SimPlan','新增模块的父子系统不存在。');
                        if ~isempty(parent) && ~ismember(parent,added), obj.assertEditable(parent); end
                        if strcmp(obj.Scope,'selection')
                            parents=cellfun(@parentOf,obj.Selected,'UniformOutput',false);
                            assert(ismember(parent,parents) || ismember(parent,added),'MatlabAI:SimScope','新增模块必须位于选中模块所在的子系统。');
                        end
                        assert(isnumeric(op.position) && numel(op.position)==4 && all(isfinite(op.position)) && ...
                            all(op.position>=0) && op.position(3)>op.position(1) && op.position(4)>op.position(2),'MatlabAI:SimPlan','模块位置无效。');
                        known{end+1}=op.path; added{end+1}=op.path;
                        obj.Summary(end+1,:)={'新增模块',op.path,op.kind};
                    case 'set'
                        exactFields(op,{'op','path','parameter','value'}); checkTarget(op.path);
                        assert(ismember(op.parameter,allowedParameters),'MatlabAI:SimParameter','此参数尚不支持预览修改。');
                        safeValue(op.value,obj.Model,op.parameter);
                        if ~ismember(op.path,added)
                            fields=get_param(obj.full(op.path),'DialogParameters');
                            assert(isfield(fields,op.parameter),'MatlabAI:SimParameter','目标模块不存在此参数。');
                            old=get_param(obj.full(op.path),op.parameter);
                        else, old='（新模块默认值）'; end
                        obj.Summary(end+1,:)={'修改参数',[op.path ' / ' op.parameter],[old ' → ' op.value]};
                    case {'connect','disconnect'}
                        exactFields(op,{'op','source','source_port','target','target_port'});
                        checkTarget(op.source); checkTarget(op.target);
                        assert(strcmp(parentOf(op.source),parentOf(op.target)),'MatlabAI:SimPorts','连接的模块必须位于同一子系统。');
                        assert(all([op.source_port op.target_port]>=1) && all(mod([op.source_port op.target_port],1)==0) && ...
                            isscalar(op.source_port) && isscalar(op.target_port),'MatlabAI:SimPorts','端口编号无效。');
                        action='连接信号'; if strcmp(op.op,'disconnect'), action='断开信号'; end
                        obj.Summary(end+1,:)={action,sprintf('%s/%d',op.source,op.source_port),sprintf('%s/%d',op.target,op.target_port)};
                    case 'function'
                        exactFields(op,{'op','path','code'}); checkTarget(op.path);
                        assert(ischar(op.code) && numel(op.code)<=300000 && startsWith(strtrim(op.code),'function'),'MatlabAI:SimFunction','模块代码必须是完整函数。');
                        if ~ismember(op.path,added)
                            chart=obj.chart(op.path);
                            assert(strcmp(functionHeader(chart.Script),functionHeader(op.code)), ...
                                'MatlabAI:SimInterface','当前修改需要保持 MATLAB Function 的函数声明与输入输出接口。');
                        end
                        obj.Summary(end+1,:)={'修改模块代码',op.path,op.code};
                    otherwise
                        error('MatlabAI:SimPlan','不支持的模型操作；未执行任何模型脚本。');
                end
            end
            obj.assertEditable('');
            function checkTarget(path)
                validPath(path);
                assert(ismember(path,known),'MatlabAI:SimPlan','目标模块不存在。');
                assert(ismember(path,obj.Allowed) || ismember(path,added),'MatlabAI:SimScope','修改超出所选模块范围。');
                if ~ismember(path,added), obj.assertEditable(path); end
            end
        end

        function assertEditable(obj,path)
            target=obj.full(path);
            while true
                callbacks=ai_simulink_callbacks(target);
                for k=1:numel(callbacks)
                    value=get_param(target,callbacks{k});
                    assert(isempty(value),'MatlabAI:SimCallback','目标 %s 含回调 %s，当前不支持自动修改该目标。',target,callbacks{k});
                end
                if strcmp(target,obj.Model), break; end
                assert(strcmp(get_param(target,'Mask'),'off'),'MatlabAI:SimMask','带 Mask 的模块请手动修改，避免触发初始化。');
                assert(ismember(get_param(target,'LinkStatus'),{'none','inactive'}),'MatlabAI:SimLink','请先手动处理库链接，再重新提问。');
                target=get_param(target,'Parent');
            end
        end

        function execute(obj,op)
            switch op.op
                case 'add'
                    catalog=ai_simulink_catalog; load_system('simulink');
                    block=add_block(catalog.(op.kind),obj.full(op.path),'Position',op.position);
                    obj.Journal{end+1}=struct('op','remove','path',op.path,'handle',block);
                case 'set'
                    if ismember(op.parameter,{'Inputs','NumInputPorts','Port'})
                        ports=get_param(obj.full(op.path),'PortHandles');
                        connected=false;
                        for p=[ports.Inport(:); ports.Outport(:)]'
                            connected=connected || get_param(p,'Line')>0;
                        end
                        assert(~connected,'MatlabAI:SimPorts','改变端口配置前必须先断开模块连接，以便可靠恢复。');
                    end
                    old=get_param(obj.full(op.path),op.parameter);
                    obj.Journal{end+1}=struct('op','set','path',op.path,'parameter',op.parameter,'value',old);
                    set_param(obj.full(op.path),op.parameter,op.value);
                case 'function'
                    chart=obj.chart(op.path);
                    obj.Journal{end+1}=struct('op','function','path',op.path,'code',chart.Script);
                    chart.Script=op.code;
                case 'connect'
                    [src,dst,system]=obj.ports(op);
                    assert(get_param(dst,'Line')<0,'MatlabAI:SimPorts','目标输入端口已有连接，请先在方案中断开旧连接。');
                    add_line(system,src,dst,'autorouting','on');
                    inverse=op; inverse.op='disconnect'; obj.Journal{end+1}=inverse;
                case 'disconnect'
                    [src,dst,system]=obj.ports(op);
                    line=get_param(dst,'Line');
                    assert(line>0 && get_param(line,'SrcPortHandle')==src,'MatlabAI:SimPorts','指定连接不存在。');
                    inverse=op; inverse.op='connect'; inverse.name=get_param(line,'Name');
                    delete_line(system,src,dst); obj.Journal{end+1}=inverse;
            end
        end

        function undoJournal(obj)
            while ~isempty(obj.Journal)
                op=obj.Journal{end};
                switch op.op
                    case 'remove'
                        assert(get_param(obj.full(op.path),'Handle')==op.handle,'MatlabAI:Conflict','新增模块身份已变化，不能删除。');
                        delete_block(op.handle);
                    case 'set', set_param(obj.full(op.path),op.parameter,op.value);
                    case 'function', chart=obj.chart(op.path); chart.Script=op.code;
                    case 'disconnect'
                        [src,dst,system]=obj.ports(op); delete_line(system,src,dst);
                    case 'connect'
                        [src,dst,system]=obj.ports(op); line=add_line(system,src,dst,'autorouting','on');
                        if ~isempty(op.name), set_param(line,'Name',op.name); end
                end
                obj.Journal(end)=[];
            end
        end

        function [src,dst,system]=ports(obj,op)
            a=get_param(obj.full(op.source),'PortHandles'); b=get_param(obj.full(op.target),'PortHandles');
            assert(op.source_port<=numel(a.Outport) && op.target_port<=numel(b.Inport),'MatlabAI:SimPorts','端口不存在，请核对模块端口。');
            src=a.Outport(op.source_port); dst=b.Inport(op.target_port); system=get_param(obj.full(op.source),'Parent');
        end
        function value=full(obj,path)
            if isempty(path), value=obj.Model; else, value=[obj.Model '/' path]; end
        end
        function value=chart(obj,path)
            value=find(sfroot,'-isa','Stateflow.EMChart','Path',obj.full(path));
            assert(isscalar(value),'MatlabAI:SimFunction','目标不是 MATLAB Function 模块。');
        end
    end
end

function fields=allowedParameters()
fields={'Gain','Value','Inputs','Numerator','Denominator','SampleTime','InitialCondition', ...
    'UpperLimit','LowerLimit','Amplitude','Bias','Frequency','Phase','Time','Before','After', ...
    'Port','NumInputPorts','Multiplication','ZeroCross','ExternalReset','LimitOutput','IntegratorMethod','OutDataTypeStr'};
end
function safeValue(value,model,parameter)
assert(ischar(value) && numel(value)<=2000,'MatlabAI:SimValue','参数值无效。');
enums=struct('Multiplication',{{'Element-wise(K.*u)','Matrix(K*u)','Element-wise(.*)','Matrix(*)'}}, ...
    'ZeroCross',{{'on','off'}},'LimitOutput',{{'on','off'}}, ...
    'ExternalReset',{{'none','rising','falling','either','level','sampled level'}}, ...
    'IntegratorMethod',{{'Integration: Forward Euler','Integration: Backward Euler','Integration: Trapezoidal'}}, ...
    'OutDataTypeStr',{{'double','single','boolean','int8','uint8','int16','uint16','int32','uint32','Inherit: Inherit via back propagation','Inherit: Same as input'}});
if isfield(enums,parameter)
    assert(ismember(value,enums.(parameter)),'MatlabAI:SimValue','参数枚举值不受支持。'); return;
end
assert(~isempty(regexp(value,'^[A-Za-z0-9_ .+*/^()\[\],:;\-]+$','once')) && ...
    isempty(regexp(value,'[A-Za-z_]\w*\s*\(','once')) && ...
    ~contains(regexprep(value,'\[[^\[\]]*\]',''),';'),'MatlabAI:SimValue','参数仅接受数值、变量名或简单算术表达式，不接受命令或函数调用。');
names=regexp(value,'(?<![A-Za-z0-9_])[A-Za-z_]\w*','match');
names=setdiff(names,{'pi','Inf','inf','NaN','nan','true','false'});
if isempty(names), return; end
% Inspect variable metadata only. Never evaluate a parameter expression.
variables=evalin('base','whos'); workspace=get_param(model,'ModelWorkspace');
variables=[variables(:); whos(workspace)];
numeric={'double','single','logical','int8','uint8','int16','uint16','int32','uint32','int64','uint64'};
for k=1:numel(names)
    found=find(strcmp({variables.name},names{k}),1,'last');
    assert(~isempty(found) && ismember(variables(found).class,numeric), ...
        'MatlabAI:SimValue','参数变量必须是已有的数值或逻辑变量；不执行未解析的名称。');
end
end
function validPath(path)
assert(ischar(path) && ~isempty(path) && numel(path)<500 && ~startsWith(path,'/') && ~endsWith(path,'/') && ...
    ~contains(path,'//') && isempty(regexp(path,'[\r\n\\]','once')) && ...
    ~any(ismember(strsplit(path,'/'),{'.','..'})),'MatlabAI:SimPath','模块路径必须是模型内的相对路径。');
end
function exactFields(value,names)
assert(isequal(sort(fieldnames(value)),sort(names(:))),'MatlabAI:SimPlan','操作包含未知或缺失字段。');
end
function value=parentOf(path)
index=find(path=='/',1,'last');
if isempty(index), value=''; else, value=path(1:index-1); end
end
function result=asCells(value)
if iscell(value), result=value; elseif isstruct(value), result=num2cell(value); else, error('MatlabAI:SimPlan','操作列表无效。'); end
end
function bytes=readFile(path)
bytes=[]; if isempty(path) || ~isfile(path), return; end
fid=fopen(path,'rb'); assert(fid>=0,'MatlabAI:SimFile','无法读取模型文件。');
cleanup=onCleanup(@() fclose(fid)); bytes=fread(fid,Inf,'*uint8');
end
function header=functionHeader(code)
header=regexp(code,'(?m)^\s*function[^\r\n]*','match','once');
header=regexprep(header,'%.*',''); header=regexprep(header,'\s','');
end
