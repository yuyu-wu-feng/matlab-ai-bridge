function result=ai_upgrade_ui()
% Install new controls without inspecting any model, editor or workspace.
app=matlab_ai;
result=jsonencode(struct('ok',true,'modes',{app.Mode.Items}, ...
    'simulink_available',~isempty(app.SimulinkTab) && isvalid(app.SimulinkTab)));
end
