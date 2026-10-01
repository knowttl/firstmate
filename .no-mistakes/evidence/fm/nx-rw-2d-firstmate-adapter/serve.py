import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI
from app.db import engine
from app.models import Base
from app.models.experiment_listener import ExperimentListener
from app.routes.experiments import router as experiments
from app.routes.experiment_decisions import router as decisions
from app.routes.experiment_messages import router as messages
from app.routes.catalog import router as catalog


@asynccontextmanager
async def lifespan(app):
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield
    await engine.dispose()


app = FastAPI(lifespan=lifespan)
for router in (experiments, decisions, messages, catalog):
    app.include_router(router, prefix="/api/v1")
