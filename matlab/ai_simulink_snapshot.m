function state=ai_simulink_snapshot(model)
% Bounded structural read, without loading referenced models or evaluating
% parameters. Selection is deliberately separate from the conflict snapshot.
assert(bdIsLoaded(model),'MatlabAI:SimClosed','目标模型已关闭，请重新读取。');
assert(strcmp(get_param(model,'BlockDiagramType'),'model'),'MatlabAI:SimLibrary','请选择模型而非库。');
paths=find_system(model,'LookUnderMasks','none','FollowLinks','off','Type','Block');
paths=sort(paths); assert(numel(paths)<=400,'MatlabAI:SimSize','模型超过 400 个可见模块，请先使用较小的模型。');
blocks=struct('path',{},'type',{},'identity',{},'position',{},'orientation',{},'parameters',{},'inputs',{},'outputs',{},'script',{},'masked',{},'link',{},'callbacks',{});
for k=1:numel(paths)
    p=paths{k}; parameters=struct;
    dialog=get_param(p,'DialogParameters');
    if isstruct(dialog)
        names=sort(fieldnames(dialog));
        for j=1:numel(names)
            try
                value=get_param(p,names{j});
                if ischar(value) && numel(value)<=10000, parameters.(names{j})=value; end
            catch
            end
        end
    end
    ports=get_param(p,'PortHandles'); script='';
    if strcmp(get_param(p,'BlockType'),'SubSystem') && strcmp(get_param(p,'SFBlockType'),'MATLAB Function')
        chart=find(sfroot,'-isa','Stateflow.EMChart','Path',p);
        if isscalar(chart), script=chart.Script; end
    end
    blocks(end+1)=struct('path',p(numel(model)+2:end),'type',get_param(p,'BlockType'),'identity',get_param(p,'Handle'), ...
        'position',get_param(p,'Position'),'orientation',get_param(p,'Orientation'), ...
        'parameters',parameters,'inputs',numel(ports.Inport),'outputs',numel(ports.Outport), ...
        'script',script,'masked',get_param(p,'Mask'),'link',get_param(p,'LinkStatus'),'callbacks',callbackValues(p));
end
edges=struct('source',{},'source_port',{},'target',{},'target_port',{},'name',{});
for k=1:numel(paths)
    ports=get_param(paths{k},'PortHandles');
    for j=1:numel(ports.Inport)
        line=get_param(ports.Inport(j),'Line');
        if line<0, continue; end
        source=get_param(line,'SrcPortHandle');
        if source<0, continue; end
        sourceBlock=get_param(source,'Parent');
        edges(end+1)=struct('source',sourceBlock(numel(model)+2:end), ...
            'source_port',get_param(source,'PortNumber'), ...
            'target',paths{k}(numel(model)+2:end),'target_port',j,'name',get_param(line,'Name'));
    end
end
settings=struct;
for field={'Solver','SolverType','StartTime','StopTime','FixedStep'}
    settings.(field{1})=get_param(model,field{1});
end
state=struct('model',model,'release',version('-release'),'settings',settings,'blocks',blocks,'connections',edges,'callbacks',callbackValues(model));
assert(numel(jsonencode(state))<=300000,'MatlabAI:SimSize','模型上下文过大，请使用较小的模型。');
end

function result=callbackValues(target)
names=ai_simulink_callbacks(target);
result=struct;
for k=1:numel(names)
    value=get_param(target,names{k});
    if ischar(value) && ~isempty(value), result.(names{k})=value; end
end
end
