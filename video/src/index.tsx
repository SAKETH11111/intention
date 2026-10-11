import React, {useEffect, useMemo, useRef, useState} from 'react';
import {AbsoluteFill, Composition, cancelRender, continueRender, delayRender, registerRoot, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import timeline from '../timeline.json';
import './video.css';
import {FPS, LAUNCH_SECONDS, Launch} from './launch';
import {FPS2, LAUNCH2_SECONDS, Launch2} from './launch2';
import {FPS3, LAUNCH3_FRAMES, Launch3} from './launch3';

type StageAPI = {
  ready?: Promise<boolean>;
  seek?: (seconds: number) => void;
  seekFrame?: (frame: number, fps?: number) => void;
  seekScene?: (id: string, seconds: number) => void;
  go: (id: string) => void;
  snap: () => void;
  state: () => {scene: string; phase: string};
};
type StageWindow = Window & {stage?: StageAPI};

function Demo() {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const seconds = frame / fps;
  const chapter = timeline.chapters.find(c => seconds >= c.start && seconds < c.end) ?? timeline.chapters[0];
  const iframe = useRef<HTMLIFrameElement>(null);
  const [loaded, setLoaded] = useState(false);
  const handle = useMemo(() => delayRender(`Stage frame ${frame}`, {timeoutInMilliseconds: 60000}), [frame]);
  useEffect(() => {
    if (!loaded) return;
    let cancelled = false;
    const apply = async () => {
      const win = iframe.current?.contentWindow as StageWindow | null;
      const doc = win?.document;
      if (!win?.stage || !doc) throw new Error('The stage did not expose window.stage');
      await Promise.all([doc.fonts.ready, document.fonts.ready]);
      const api = win.stage;
      await api.ready;
      if (api.seekFrame) api.seekFrame(frame, fps);
      else if (api.seek) api.seek(seconds);
      else if (api.seekScene) api.seekScene(chapter.id, seconds - chapter.start);
      else throw new Error('A deterministic stage seek API is required');
      await Promise.all([...doc.images].map(img => img.decode().catch(() => undefined)));
      // Let iframe layout and paint finish before Remotion captures this frame.
      await new Promise<void>(resolve => win.requestAnimationFrame(() => win.requestAnimationFrame(() => resolve())));
      if (!cancelled) continueRender(handle);
    };
    apply().catch(cancelRender);
    return () => {cancelled = true; continueRender(handle);};
  }, [loaded, frame, fps, seconds, chapter.id, chapter.start, handle]);
  return <AbsoluteFill className="video-root">
    <iframe ref={iframe} title="Intention synthetic desktop" src={`${staticFile('stage/index.html')}?render=1`} onLoad={() => setLoaded(true)} />
  </AbsoluteFill>;
}

registerRoot(() => <>
  <Composition id="IntentionDemo" component={Demo} durationInFrames={timeline.durationInFrames} fps={timeline.fps} width={timeline.width} height={timeline.height} />
  <Composition id="IntentionLaunch" component={Launch} durationInFrames={LAUNCH_SECONDS * FPS} fps={FPS} width={1920} height={1080} />
  <Composition id="IntentionLaunch2" component={Launch2} durationInFrames={LAUNCH2_SECONDS * FPS2} fps={FPS2} width={1920} height={1080} />
  <Composition id="IntentionLaunch3" component={Launch3} durationInFrames={LAUNCH3_FRAMES} fps={FPS3} width={1920} height={1080} />
</>);
