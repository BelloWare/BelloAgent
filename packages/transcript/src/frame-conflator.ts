interface FrameRuntime {
  frame(callback:()=>void):number;
  cancelFrame(id:number):void;
  task(callback:()=>void):number;
  cancelTask(id:number):void;
}
// One latest pending value, at most two post-paint tasks, and no idle polling.
// Acknowledgments correspond to values actually rendered during a frame.
export function frameConflator<T>(render:(value:T)=>unknown, painted:(value:T)=>void, runtime:FrameRuntime) {
  let pending:T|undefined, frame=0, disposed=false;
  const tasks=new Set<number>();
  const schedule=()=>{
    if(disposed || frame || pending===undefined || tasks.size>=2)return;
    frame=runtime.frame(()=>{
      frame=0;const cutoff=pending!;pending=undefined;
      // A React error boundary can commit its fallback without drawing the
      // transcript. Do not acknowledge that fallback as a successful paint.
      if(render(cutoff)===false){schedule();return;}
      const task=runtime.task(()=>{tasks.delete(task);if(!disposed){painted(cutoff);schedule();}});
      tasks.add(task);
    });
  };
  return {
    push(value:T){if(!disposed){pending=value;schedule();}},
    dispose(){disposed=true;pending=undefined;runtime.cancelFrame(frame);for(const task of tasks)runtime.cancelTask(task);tasks.clear();},
  };
}
